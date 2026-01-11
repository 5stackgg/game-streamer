#!/usr/bin/env bash
# Install gbe_fork (maintained Goldberg fork) as the steamclient.so stub.
# This replaces the real Steam-running requirement so CS2 can launch and
# playdemo / +connect without a live Steam client in the pod.
#
# Usage:
#   ./scripts/install-gbe-fork.sh install        # download + wire up
#   ./scripts/install-gbe-fork.sh uninstall      # restore original symlink
#   ./scripts/install-gbe-fork.sh status         # show current state
#
# After install, test with:
#   ./scripts/live.sh     (with CONNECT_ADDR + CONNECT_PASSWORD set)
# or render.sh for demo playback.

set -euo pipefail

: "${CS2_DIR:=/mnt/game-streamer/cs2}"

STUB_DIR=/opt/gbe_fork
SDK64_LINK=/root/.steam/sdk64/steamclient.so
SDK64_BACKUP=/root/.steam/sdk64/steamclient.so.real

say() { printf '\n=== %s ===\n' "$*"; }

cmd_status() {
  say "GBE_FORK INSTALL"
  if [ -f "$STUB_DIR/steamclient.so" ]; then
    ls -la "$STUB_DIR/"
  else
    echo "  not installed at $STUB_DIR"
  fi

  say "CURRENT sdk64 STEAMCLIENT"
  ls -la "$SDK64_LINK" 2>/dev/null || echo "  symlink missing"
  if [ -L "$SDK64_LINK" ]; then
    local tgt; tgt=$(readlink "$SDK64_LINK")
    if [[ "$tgt" == "$STUB_DIR"* ]]; then
      echo "  -> USING gbe_fork stub"
    else
      echo "  -> USING real Steam runtime"
    fi
  fi

  say "CS2 steam_appid.txt"
  ls -la "$CS2_DIR/game/csgo/steam_appid.txt" 2>/dev/null || echo "  missing"
  ls -la "$CS2_DIR/game/bin/linuxsteamrt64/steam_appid.txt" 2>/dev/null || echo "  (no sibling appid file)"
}

cmd_install() {
  local tag="${1:-latest}"
  say "installing gbe_fork (release: $tag)"
  mkdir -p "$STUB_DIR"

  # Prefer release (not debug) emu-linux asset, fall back to any emu-linux.
  local asset_url=""
  local releases_json
  if [ "$tag" = "latest" ]; then
    releases_json=$(curl -fsSL https://api.github.com/repos/Detanup01/gbe_fork/releases/latest)
  else
    releases_json=$(curl -fsSL "https://api.github.com/repos/Detanup01/gbe_fork/releases/tags/$tag")
  fi
  for pat in 'emu-linux-release[^"]*' 'emu-linux[^"]*'; do
    asset_url=$(echo "$releases_json" \
      | grep -oE '"browser_download_url"\s*:\s*"[^"]*'"$pat"'"' \
      | head -1 \
      | sed -E 's/.*"(https[^"]+)"/\1/')
    [ -n "$asset_url" ] && break
  done

  if [ -z "$asset_url" ]; then
    echo "FAIL: could not find an emu-linux asset in the latest gbe_fork release"
    echo "  assets found:"
    echo "$releases_json" | grep browser_download_url | sed 's/^/    /'
    exit 1
  fi

  echo "  downloading: $asset_url"
  local fname; fname=$(basename "$asset_url")
  curl -fsSL -o "/tmp/$fname" "$asset_url" || {
    echo "FAIL: download failed"; exit 1;
  }

  echo "  extracting /tmp/$fname"
  rm -rf /tmp/gbe_extract; mkdir /tmp/gbe_extract
  case "$fname" in
    *.tar.bz2|*.tbz2)
      command -v bzip2 >/dev/null 2>&1 || {
        echo "  installing bzip2"
        apt-get update -qq && apt-get install -y -qq bzip2
      }
      tar -xjf "/tmp/$fname" -C /tmp/gbe_extract
      ;;
    *.tar.gz|*.tgz)   tar -xzf "/tmp/$fname" -C /tmp/gbe_extract ;;
    *.tar.xz)         tar -xJf "/tmp/$fname" -C /tmp/gbe_extract ;;
    *.zip)            unzip -q "/tmp/$fname" -d /tmp/gbe_extract ;;
    *.7z)             command -v 7z >/dev/null 2>&1 || apt-get install -y p7zip-full >/dev/null 2>&1
                      7z x -o/tmp/gbe_extract "/tmp/$fname" >/dev/null ;;
    *)                echo "unknown archive: $fname"; exit 1 ;;
  esac
  echo "  extracted tree (top 3 levels):"
  find /tmp/gbe_extract -maxdepth 3 -type d | sed 's/^/    /'

  # Prefer the REGULAR build — experimental links against newer GLIBC
  # (2.34+) which sniper (Debian 11 / bullseye, GLIBC 2.31) can't load.
  local sc
  sc=$(find /tmp/gbe_extract -type f -name steamclient.so -path '*regular*x64*' 2>/dev/null | head -1)
  [ -z "$sc" ] && sc=$(find /tmp/gbe_extract -type f -name steamclient.so -path '*regular*x86_64*' 2>/dev/null | head -1)
  [ -z "$sc" ] && sc=$(find /tmp/gbe_extract -type f -name steamclient.so -path '*x64*' ! -path '*x32*' 2>/dev/null | head -1)
  [ -z "$sc" ] && sc=$(find /tmp/gbe_extract -type f -name steamclient.so 2>/dev/null | head -1)
  if [ -z "$sc" ]; then
    echo "FAIL: no steamclient.so found in archive"
    find /tmp/gbe_extract -maxdepth 4 -type d | head -20
    exit 1
  fi
  echo "  found steamclient.so at: $sc"

  # sanity-check GLIBC compat against host libc. strings works even
  # without binutils; grep the raw .so for GLIBC_ version strings.
  local needs
  needs=$(strings "$sc" 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1)
  local have
  have=$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$')
  echo "  stub wants highest: ${needs:-<unknown>}, host libc: ${have:-<unknown>}"
  if [ -n "$needs" ] && [ -n "$have" ]; then
    # naive major.minor compare
    if printf '%s\n%s\n' "${needs#GLIBC_}" "$have" | sort -V -c 2>/dev/null; then
      echo "  GLIBC OK"
    else
      echo "  WARN: stub needs newer GLIBC than host — CS2 will fail dlopen"
    fi
  fi

  cp -v "$sc" "$STUB_DIR/steamclient.so"

  # matching libsteam_api from the same build dir (regular if that's what we used)
  local api
  api=$(find "$(dirname "$sc")" -type f -name libsteam_api.so 2>/dev/null | head -1)
  [ -z "$api" ] && api=$(find /tmp/gbe_extract -type f -name libsteam_api.so -path '*regular*x64*' 2>/dev/null | head -1)
  [ -z "$api" ] && api=$(find /tmp/gbe_extract -type f -name libsteam_api.so 2>/dev/null | head -1)
  if [ -n "$api" ]; then
    cp -v "$api" "$STUB_DIR/libsteam_api.so"
  fi

  say "wiring sdk64/steamclient.so -> stub"
  mkdir -p "$(dirname "$SDK64_LINK")"
  # preserve the original symlink / file so uninstall can restore it
  if [ -e "$SDK64_LINK" ] && [ ! -e "$SDK64_BACKUP" ]; then
    if [ -L "$SDK64_LINK" ]; then
      local orig; orig=$(readlink "$SDK64_LINK")
      ln -sfn "$orig" "$SDK64_BACKUP"
      echo "  backed up original symlink: $orig -> $SDK64_BACKUP"
    else
      mv "$SDK64_LINK" "$SDK64_BACKUP"
      echo "  backed up original file -> $SDK64_BACKUP"
    fi
  fi
  ln -sfn "$STUB_DIR/steamclient.so" "$SDK64_LINK"

  say "writing steam_appid.txt for CS2 (appid 730)"
  echo 730 > "$CS2_DIR/game/csgo/steam_appid.txt"
  echo 730 > "$CS2_DIR/game/bin/linuxsteamrt64/steam_appid.txt"

  say "done"
  echo "  CS2 should now launch without a running Steam client."
  echo "  test with:"
  echo "    export MATCH_ID=<uuid> CONNECT_ADDR=host:port CONNECT_PASSWORD='tv:user:xxx'"
  echo "    /opt/5stack/scripts/live.sh"
  echo ""
  echo "  to revert: $0 uninstall"
}

cmd_uninstall() {
  say "restoring original sdk64/steamclient.so"
  if [ -e "$SDK64_BACKUP" ]; then
    if [ -L "$SDK64_BACKUP" ]; then
      local orig; orig=$(readlink "$SDK64_BACKUP")
      ln -sfn "$orig" "$SDK64_LINK"
      rm "$SDK64_BACKUP"
      echo "  restored symlink -> $orig"
    else
      mv "$SDK64_BACKUP" "$SDK64_LINK"
      echo "  restored original file"
    fi
  else
    echo "  no backup found at $SDK64_BACKUP — nothing to restore"
  fi
  rm -f "$CS2_DIR/game/csgo/steam_appid.txt" 2>/dev/null || true
  rm -f "$CS2_DIR/game/bin/linuxsteamrt64/steam_appid.txt" 2>/dev/null || true
  echo "  done"
}

case "${1:-status}" in
  install)   shift; cmd_install "$@" ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status ;;
  *) echo "usage: $0 install [release-tag] | uninstall | status"; exit 2 ;;
esac
