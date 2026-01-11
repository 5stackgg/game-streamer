#!/usr/bin/env bash
# Build gbe_fork from source inside the sniper container so the resulting
# steamclient.so links against sniper's own GLIBC (2.31, bullseye-era).
# Pre-built gbe_fork binaries target GLIBC 2.32+, which sniper can't load.
#
# Usage:
#   ./scripts/build-gbe-fork.sh            # clone + build + install
#   ./scripts/build-gbe-fork.sh clean      # remove build tree
#
# Notes:
#   - Takes ~5-10 min on first run (compiles protobuf, curl deps, etc).
#   - Output lands at /opt/gbe_fork/{steamclient.so,libsteam_api.so}.
#   - Wires /root/.steam/sdk64/steamclient.so -> /opt/gbe_fork/steamclient.so.
#   - steam_appid.txt for CS2 written automatically.

set -euo pipefail

: "${CS2_DIR:=/mnt/game-streamer/cs2}"

BUILD_DIR=/opt/gbe_fork_src
STUB_DIR=/opt/gbe_fork
SDK64_LINK=/root/.steam/sdk64/steamclient.so
SDK64_BACKUP=/root/.steam/sdk64/steamclient.so.real

say() { printf '\n=== %s ===\n' "$*"; }

cmd_clean() {
  rm -rf "$BUILD_DIR"
  echo "removed $BUILD_DIR"
}

cmd_install() {
  say "installing build prerequisites"
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    git cmake ninja-build build-essential pkg-config \
    python3 python3-pip \
    libssl-dev zlib1g-dev >/dev/null

  say "cloning gbe_fork (with submodules) into $BUILD_DIR"
  if [ -d "$BUILD_DIR/.git" ]; then
    git -C "$BUILD_DIR" fetch --tags
    git -C "$BUILD_DIR" submodule update --init --recursive
  else
    git clone --recursive https://github.com/Detanup01/gbe_fork.git "$BUILD_DIR"
  fi

  cd "$BUILD_DIR"

  say "installing premake + extra build deps"
  apt-get install -y --no-install-recommends premake4 >/dev/null 2>&1 || true
  # gbe_fork uses premake5; try apt first, else download binary
  if ! command -v premake5 >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends premake >/dev/null 2>&1 || true
  fi
  if ! command -v premake5 >/dev/null 2>&1; then
    say "fetching premake5 binary"
    curl -fsSL -o /tmp/premake5.tar.gz \
      https://github.com/premake/premake-core/releases/download/v5.0.0-beta2/premake-5.0.0-beta2-linux.tar.gz
    tar -xzf /tmp/premake5.tar.gz -C /usr/local/bin
    chmod +x /usr/local/bin/premake5
  fi
  premake5 --version

  say "building gbe_fork emu (regular, 64-bit) via build_linux_premake.sh"
  chmod +x ./build_linux_premake.sh
  ./build_linux_premake.sh

  say "locating produced steamclient.so / libsteam_api.so"
  local out_dir
  out_dir=$(find "$BUILD_DIR" -type d -name 'linux*64*' -path '*release*' 2>/dev/null | head -1)
  [ -z "$out_dir" ] && out_dir=$(find "$BUILD_DIR/build" -type d 2>/dev/null | head -5)
  local sc
  sc=$(find "$BUILD_DIR" -type f -name 'steamclient.so' 2>/dev/null | head -1)
  local api
  api=$(find "$BUILD_DIR" -type f -name 'libsteam_api.so' 2>/dev/null | head -1)

  if [ -z "$sc" ]; then
    echo "FAIL: no steamclient.so produced. Build tree:"
    find "$BUILD_DIR/build" -maxdepth 3 -type d 2>/dev/null | head -20
    exit 1
  fi
  echo "  steamclient.so -> $sc"
  [ -n "$api" ] && echo "  libsteam_api.so -> $api"

  say "installing to $STUB_DIR + sdk64 symlink"
  mkdir -p "$STUB_DIR"
  cp -v "$sc" "$STUB_DIR/steamclient.so"
  [ -n "$api" ] && cp -v "$api" "$STUB_DIR/libsteam_api.so"

  if [ ! -e "$SDK64_BACKUP" ] && [ -e "$SDK64_LINK" ]; then
    if [ -L "$SDK64_LINK" ]; then
      ln -sfn "$(readlink "$SDK64_LINK")" "$SDK64_BACKUP"
    else
      mv "$SDK64_LINK" "$SDK64_BACKUP"
    fi
    echo "  backed up original steamclient.so"
  fi
  mkdir -p "$(dirname "$SDK64_LINK")"
  ln -sfn "$STUB_DIR/steamclient.so" "$SDK64_LINK"

  say "writing steam_appid.txt for CS2"
  echo 730 > "$CS2_DIR/game/csgo/steam_appid.txt"
  echo 730 > "$CS2_DIR/game/bin/linuxsteamrt64/steam_appid.txt"

  say "GLIBC compat sanity check"
  ldd "$STUB_DIR/steamclient.so" 2>&1 | head -10 || true

  say "done"
  echo "  test: /opt/5stack/scripts/live.sh"
  echo "  revert: /opt/5stack/scripts/install-gbe-fork.sh uninstall"
}

case "${1:-install}" in
  install) cmd_install ;;
  clean)   cmd_clean ;;
  *) echo "usage: $0 install | clean"; exit 2 ;;
esac
