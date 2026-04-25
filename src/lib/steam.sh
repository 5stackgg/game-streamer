# shellcheck shell=bash
# Steam-specific helpers: bootstrap install, library registration, start/stop,
# pipe-up wait, and gbe_fork stub <-> real-client swap.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SDK64_LINK=/root/.steam/sdk64/steamclient.so
SDK64_BACKUP=/root/.steam/sdk64/steamclient.so.real

steam_pipe_up() {
  [ -p "$HOME/.steam/steam.pipe" ] && [ -f "$HOME/.steam/steam.pid" ] \
    && kill -0 "$(cat "$HOME/.steam/steam.pid" 2>/dev/null)" 2>/dev/null
}

steam_bootstrap_extracted() {
  [ -x "$STEAM_HOME/steam.sh" ]
}

# Download + unpack the Steam bootstrap into $STEAM_HOME if missing.
ensure_steam_bootstrap() {
  if steam_bootstrap_extracted; then return 0; fi

  command -v xz >/dev/null 2>&1 || {
    log "installing xz-utils"
    apt-get update -qq && apt-get install -y -qq xz-utils
  }
  log "downloading + extracting Steam bootstrap into $STEAM_HOME"
  mkdir -p "$STEAM_HOME"
  curl -fsSL -o /tmp/steam.deb \
    https://cdn.cloudflare.steamstatic.com/client/installer/steam.deb
  dpkg-deb -x /tmp/steam.deb /tmp/steamdeb
  local bootstrap
  bootstrap=$(find /tmp/steamdeb -name 'bootstraplinux_ubuntu12_32.tar.xz' | head -1)
  tar -xJf "$bootstrap" -C "$STEAM_HOME"
  rm -rf /tmp/steam.deb /tmp/steamdeb
  steam_bootstrap_extracted || die "bootstrap extract failed"
}

# Make sure sdk64/steamclient.so points at the real Steam runtime, not the
# gbe_fork stub. Real Steam needs its own steamclient.so for IPC.
restore_real_steamclient() {
  if [ ! -L "$SDK64_LINK" ]; then return 0; fi
  if ! readlink -f "$SDK64_LINK" 2>/dev/null | grep -q '/opt/gbe_fork'; then
    return 0
  fi
  log "swapping sdk64/steamclient.so back to real Steam runtime"
  rm -f "$SDK64_LINK"
  if [ -e "$SDK64_BACKUP" ]; then
    if [ -L "$SDK64_BACKUP" ]; then
      ln -sfn "$(readlink "$SDK64_BACKUP")" "$SDK64_LINK"
    else
      mv "$SDK64_BACKUP" "$SDK64_LINK"
    fi
  else
    local sc
    sc=$(find "$STEAM_HOME" -name 'steamclient.so' -path '*linux64*' 2>/dev/null | head -1)
    [ -n "$sc" ] && ln -sfn "$sc" "$SDK64_LINK"
  fi
  # Stub-era appid hints confuse real Steam.
  rm -f "$STEAM_LIBRARY/cs2/game/csgo/steam_appid.txt" \
        "$STEAM_LIBRARY/cs2/game/bin/linuxsteamrt64/steam_appid.txt" 2>/dev/null || true
}

# Write libraryfolders.vdf so Steam treats $STEAM_LIBRARY as a real library
# the moment it boots. Idempotent — leaves an existing entry alone.
register_library() {
  local lib="${1:-$STEAM_LIBRARY}"
  mkdir -p "$lib/steamapps/common"

  cat > "$lib/libraryfolder.vdf" <<EOF
"libraryfolder"
{
    "contentid"        "0"
    "label"            ""
}
EOF

  local lf="$STEAM_HOME/config/libraryfolders.vdf"
  mkdir -p "$(dirname "$lf")"
  if [ ! -f "$lf" ]; then
    cat > "$lf" <<EOF
"libraryfolders"
{
    "0"
    {
        "path"        "$STEAM_HOME"
        "label"       ""
        "contentid"   "0"
    }
    "1"
    {
        "path"        "$lib"
        "label"       "game-streamer hostpath"
        "contentid"   "0"
    }
}
EOF
    log "wrote fresh $lf with $lib"
    return 0
  fi

  if grep -q "\"$lib\"" "$lf"; then
    log "$lib already registered in $lf"
    return 0
  fi

  log "appending $lib to existing $lf"
  python3 - "$lf" "$lib" <<'PY'
import re, sys, pathlib
lf = pathlib.Path(sys.argv[1])
path = sys.argv[2]
src = lf.read_text()
idxs = [int(m.group(1)) for m in re.finditer(r'"(\d+)"\s*\{', src)]
nxt = max(idxs) + 1 if idxs else 0
entry = f'''
    "{nxt}"
    {{
        "path"        "{path}"
        "label"       "game-streamer hostpath"
        "contentid"   "0"
    }}
'''
src = src.rstrip()
if src.endswith("}"):
    src = src[:-1] + entry + "}\n"
lf.write_text(src)
PY
}

# One-time migration of legacy CS2 install at $STEAM_LIBRARY/cs2 into the
# canonical Steam library layout. No-op once moved.
migrate_legacy_cs2() {
  local src="$STEAM_LIBRARY/cs2"
  local dst="$CS2_DIR"
  if [ -d "$src" ] && [ ! -e "$dst" ]; then
    log "migrating legacy CS2 install: $src -> $dst"
    mkdir -p "$(dirname "$dst")"
    mv "$src" "$dst"
  fi

  # Pull the manifest up out of the install dir if a prior steamcmd run
  # put it there, so Steam picks it up.
  local manifest="$dst/steamapps/appmanifest_730.acf"
  if [ -f "$manifest" ]; then
    mv "$manifest" "$STEAM_LIBRARY/steamapps/appmanifest_730.acf"
    rmdir "$dst/steamapps" 2>/dev/null || true
    sed -i 's|"installdir"[[:space:]]*"[^"]*"|"installdir"\t\t"Counter-Strike Global Offensive"|' \
      "$STEAM_LIBRARY/steamapps/appmanifest_730.acf"
    log "moved manifest into $STEAM_LIBRARY/steamapps/"
  fi
}

# Set Steam Cloud sync to OFF for CS2 (appid 730) in every user's
# localconfig.vdf. CS2's "Cloud Out of Date" / "Play anyway" prompt is a
# CEF dialog with no X11 title — xdotool can't reliably target it — so we
# stop it from firing in the first place.
#
# Steam rewrites localconfig.vdf on shutdown, so this is a no-op while
# Steam is running. Call BEFORE start_steam.
disable_cs2_cloud() {
  if pgrep -f '/ubuntu12_32/steam' >/dev/null 2>&1; then
    log "disable_cs2_cloud: Steam is running — skip (would be clobbered on shutdown)"
    return 0
  fi
  local userdata_root="$STEAM_HOME/userdata"
  if [ ! -d "$userdata_root" ]; then
    log "disable_cs2_cloud: no userdata yet (first boot) — skip"
    return 0
  fi

  local user_dir steamid cfg edited=0
  shopt -s nullglob
  for user_dir in "$userdata_root"/*/; do
    steamid=$(basename "$user_dir")
    case "$steamid" in ''|*[!0-9]*) continue ;; esac
    cfg="$user_dir/config/localconfig.vdf"
    [ -f "$cfg" ] || continue
    python3 - "$cfg" 730 <<'PY'
import re, sys, pathlib

cfg_path, appid = sys.argv[1], sys.argv[2]
p = pathlib.Path(cfg_path)
src = p.read_text()

pat = re.compile(r'(^|\n)([ \t]*)"' + re.escape(appid) + r'"[ \t\r\n]*\{', re.MULTILINE)
m = pat.search(src)
if not m:
    apps = re.search(r'(\n[ \t]*)"apps"[ \t\r\n]*\{', src)
    if not apps:
        print(f"  {cfg_path}: no 'apps' section yet — skipping (Steam writes it on first launch)")
        sys.exit(0)
    indent = apps.group(1).rstrip("\n")
    insertion = (
        f'{indent}\t"{appid}"\n{indent}\t{{\n'
        f'{indent}\t\t"cloudenabled"\t\t"0"\n{indent}\t}}\n'
    )
    p.write_text(src[:apps.end()] + insertion + src[apps.end():])
    print(f"  {cfg_path}: inserted new {appid} block with cloudenabled=0")
    sys.exit(0)

brace_open = m.end() - 1
depth, i = 1, brace_open + 1
while i < len(src) and depth > 0:
    if src[i] == '{': depth += 1
    elif src[i] == '}': depth -= 1
    i += 1
if depth != 0:
    print(f"  {cfg_path}: unbalanced braces — refusing to edit")
    sys.exit(1)
brace_close = i - 1
block = src[brace_open + 1:brace_close]
indent = m.group(2) + "\t"

ce = re.search(r'(^|\n)([ \t]*)"cloudenabled"[ \t]+"([^"]*)"', block)
if ce:
    if ce.group(3) == "0":
        sys.exit(0)
    new_block = block[:ce.start()] \
        + f'{ce.group(1)}{ce.group(2)}"cloudenabled"\t\t"0"' \
        + block[ce.end():]
    p.write_text(src[:brace_open + 1] + new_block + src[brace_close:])
    print(f"  {cfg_path}: flipped cloudenabled to 0")
else:
    new_block = f'\n{indent}"cloudenabled"\t\t"0"' + block
    p.write_text(src[:brace_open + 1] + new_block + src[brace_close:])
    print(f"  {cfg_path}: inserted cloudenabled=0")
PY
    edited=1
  done
  shopt -u nullglob
  [ "$edited" = 0 ] && log "disable_cs2_cloud: no localconfig.vdf found yet — skip"
  return 0
}

# Kill anything left over from a prior Steam/cs2 session.
kill_steam() {
  pkill -9 -f '/linuxsteamrt64/cs2'  2>/dev/null || true
  pkill -9 -f 'ubuntu12_32/steam'    2>/dev/null || true
  pkill -9 -f '/steam.sh'            2>/dev/null || true
  pkill -9 -f 'steamwebhelper'       2>/dev/null || true
  pkill -9 -x dbus-launch            2>/dev/null || true
  rm -f "$HOME/.steam/steam.pid" "$HOME/.steam/steam.pipe" 2>/dev/null || true
  rm -rf /tmp/dumps* /tmp/source_engine_*.lock /tmp/steam_pipe_* 2>/dev/null || true
}

# Launch Steam with login prefilled. UI visible so we can watch via the
# debug stream and complete any 2FA/captcha. Logs stream into $LOG_DIR.
start_steam() {
  require_env STEAM_USERNAME STEAM_PASSWORD

  if steam_pipe_up; then
    log "steam already running (pid $(cat "$HOME/.steam/steam.pid"))"
    return 0
  fi

  ensure_steam_bootstrap
  restore_real_steamclient

  log "launching Steam with login=$STEAM_USERNAME (UI visible on debug stream)"
  (
    stdbuf -oL -eL dbus-launch --exit-with-session \
      "$STEAM_HOME/steam.sh" \
        -login "$STEAM_USERNAME" "$STEAM_PASSWORD" 2>&1 \
      | stdbuf -oL tee "$LOG_DIR/steam.log" \
      | sed -u 's/^/  [steam] /' >&2
  ) &
  log "  steam wrapper pid=$!"
}

# Wait for Steam IPC to come up. Login UI / 2FA delays go here.
wait_for_steam_pipe() {
  local timeout="${1:-300}"
  log "waiting up to ${timeout}s for steam pipe (complete login on the debug stream if needed)"
  local i
  for i in $(seq 1 "$timeout"); do
    if steam_pipe_up; then
      log "  PIPE UP after ${i}s (pid $(cat "$HOME/.steam/steam.pid"))"
      return 0
    fi
    [ $(( i % 15 )) -eq 0 ] && log "  still waiting (${i}s)"
    sleep 1
  done
  warn "steam pipe never came up after ${timeout}s"
  return 1
}
