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

# Seed $STEAM_HOME with the Steam bootstrap if missing. Prefers the copy
# baked into the image at /opt/steam-bootstrap (Dockerfile pre-extracts it);
# falls back to downloading steam.deb when running outside the image.
ensure_steam_bootstrap() {
  if steam_bootstrap_extracted; then return 0; fi

  mkdir -p "$STEAM_HOME"

  if [ -x /opt/steam-bootstrap/steam.sh ]; then
    log "seeding Steam bootstrap from /opt/steam-bootstrap into $STEAM_HOME"
    cp -a /opt/steam-bootstrap/. "$STEAM_HOME/"
    steam_bootstrap_extracted || die "bootstrap copy failed"
    return 0
  fi

  command -v xz >/dev/null 2>&1 || {
    log "installing xz-utils"
    apt-get update -qq && apt-get install -y -qq xz-utils
  }
  log "downloading + extracting Steam bootstrap into $STEAM_HOME"
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
# Edit a single VDF file (localconfig.vdf or sharedconfig.vdf) to set
# cloudenabled=0 inside the apps/<appid> block. Idempotent.
_vdf_disable_app_cloud() {
  local cfg="$1"
  [ -f "$cfg" ] || return 0
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
}

# Set Steam Cloud sync to OFF for CS2 in every user's per-account VDFs:
#   localconfig.vdf  — local-only (rewritten on Steam shutdown)
#   sharedconfig.vdf — synced across PCs (under userdata/<id>/7/remote)
# Also auto-discovers all SteamIDs (numeric subdirs of userdata/) so we
# don't need to know the SteamID up front.
#
# Steam rewrites these on shutdown; this is a no-op while Steam is
# running. Call BEFORE start_steam.
disable_cs2_cloud() {
  if pgrep -f '/ubuntu12_32/steam' >/dev/null 2>&1; then
    log "disable_cs2_cloud: Steam is running — skip (would be clobbered on shutdown)"
    return 0
  fi

  # Both common userdata paths — ~/.steam/steam is normally a symlink
  # into ~/.local/share/Steam, but if it's been replaced with a real
  # dir we want to catch that too.
  local roots=("$STEAM_HOME/userdata" "$HOME/.steam/steam/userdata")
  local seen=() root user_dir steamid edited=0
  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue
    # De-dup if both paths resolve to the same place.
    local real
    real=$(readlink -f "$root" 2>/dev/null || echo "$root")
    case " ${seen[*]} " in *" $real "*) continue ;; esac
    seen+=("$real")

    shopt -s nullglob
    for user_dir in "$root"/*/; do
      steamid=$(basename "$user_dir")
      case "$steamid" in ''|*[!0-9]*) continue ;; esac
      log "disable_cs2_cloud: SteamID $steamid (under $root)"
      _vdf_disable_app_cloud "$user_dir/config/localconfig.vdf"
      _vdf_disable_app_cloud "$user_dir/7/remote/sharedconfig.vdf"
      edited=1
    done
    shopt -u nullglob
  done

  [ "$edited" = 0 ] && log "disable_cs2_cloud: no userdata SteamIDs found yet — skip"
  return 0
}

# Disable cloud in $STEAM_HOME/config/config.vdf (the install-wide
# config, distinct from registry.vdf). Sets:
#   InstallConfigStore/Software/Valve/Steam/Cloud/EnableCloud = 0
disable_cloud_in_config_vdf() {
  if pgrep -f '/ubuntu12_32/steam' >/dev/null 2>&1; then
    log "disable_cloud_in_config_vdf: Steam is running — skip"
    return 0
  fi
  local f
  for f in "$STEAM_HOME/config/config.vdf" "$HOME/.steam/steam/config/config.vdf"; do
    [ -f "$f" ] || continue
    log "disable_cloud_in_config_vdf: editing $f"
    python3 - "$f" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()

# 1) Existing EnableCloud — flip its value.
m = re.search(r'"EnableCloud"[ \t\r\n]+"([^"]*)"', src)
if m:
    if m.group(1) == "0":
        print(f"  EnableCloud already 0 in {p}")
        sys.exit(0)
    new = re.sub(
        r'("EnableCloud"[ \t\r\n]+")[^"]*(")',
        r'\g<1>0\g<2>', src, count=1,
    )
    p.write_text(new)
    print(f"  flipped EnableCloud to 0 in {p}")
    sys.exit(0)

# 2) Existing Cloud { ... } block — inject EnableCloud into it.
m = re.search(r'"Cloud"[ \t\r\n]*\{', src)
if m:
    p.write_text(src[:m.end()] + '\n\t\t\t\t\t"EnableCloud"\t\t"0"' + src[m.end():])
    print(f"  inserted EnableCloud=0 into existing Cloud block in {p}")
    sys.exit(0)

# 3) Inject a fresh Cloud block under Steam.
def find_block_open(src, key, start=0):
    pat = re.compile(r'"' + re.escape(key) + r'"[ \t\r\n]*\{')
    m = pat.search(src, start)
    return m.end() if m else -1

ics = find_block_open(src, "InstallConfigStore")
if ics == -1:
    print(f"  no InstallConfigStore in {p} — skip"); sys.exit(0)
sw = find_block_open(src, "Software", ics)
if sw == -1: print(f"  no Software in {p}"); sys.exit(0)
v = find_block_open(src, "Valve", sw)
if v == -1: print(f"  no Valve in {p}"); sys.exit(0)
steam = find_block_open(src, "Steam", v)
if steam == -1: print(f"  no Steam in {p}"); sys.exit(0)

block = '\n\t\t\t\t"Cloud"\n\t\t\t\t{\n\t\t\t\t\t"EnableCloud"\t\t"0"\n\t\t\t\t}'
p.write_text(src[:steam] + block + src[steam:])
print(f"  inserted Cloud {{ EnableCloud=0 }} into Steam block in {p}")
PY
  done
}

# Disable Steam Cloud globally by editing registry.vdf
# (HKCU/Software/Valve/Steam/CloudEnabled = 0). This is the SAME setting
# the Steam UI exposes as "Settings → Cloud → Enable Steam Cloud sync".
# Per-app cloudenabled in localconfig.vdf isn't always sufficient — the
# global flag is the reliable kill switch for the "Cloud Out of Date" dialog.
#
# Steam rewrites registry.vdf on shutdown; call BEFORE start_steam.
disable_cloud_globally() {
  if pgrep -f '/ubuntu12_32/steam' >/dev/null 2>&1; then
    log "disable_cloud_globally: Steam is running — skip (would be clobbered on shutdown)"
    return 0
  fi
  local f
  for f in "$HOME/.steam/registry.vdf" "$STEAM_HOME/registry.vdf"; do
    [ -f "$f" ] || continue
    log "disable_cloud_globally: editing $f"
    python3 - "$f" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()

# Replace existing key value if present.
m = re.search(r'"CloudEnabled"[ \t\r\n]+"([^"]*)"', src)
if m:
    if m.group(1) == "0":
        print(f"  CloudEnabled already 0 in {p}")
        sys.exit(0)
    new = re.sub(
        r'("CloudEnabled"[ \t\r\n]+")[^"]*(")',
        r'\g<1>0\g<2>',
        src, count=1,
    )
    p.write_text(new)
    print(f"  flipped CloudEnabled to 0 in {p}")
    sys.exit(0)

# Insert into HKCU > Software > Valve > Steam.
def find_block_open(src, key, start=0):
    pat = re.compile(r'"' + re.escape(key) + r'"[ \t\r\n]*\{')
    m = pat.search(src, start)
    return m.end() if m else -1

hkcu = find_block_open(src, "HKCU")
if hkcu == -1:
    hkcu = find_block_open(src, "HKEY_CURRENT_USER")
if hkcu == -1:
    print(f"  no HKCU block in {p} — leaving untouched")
    sys.exit(1)
sw = find_block_open(src, "Software", hkcu)
if sw == -1:
    print(f"  no Software in HKCU in {p}"); sys.exit(1)
valve = find_block_open(src, "Valve", sw)
if valve == -1:
    print(f"  no Valve in Software in {p}"); sys.exit(1)
steam = find_block_open(src, "Steam", valve)
if steam == -1:
    print(f"  no Steam in Valve in {p}"); sys.exit(1)

insertion = '\n\t\t\t\t\t"CloudEnabled"\t\t"0"'
p.write_text(src[:steam] + insertion + src[steam:])
print(f"  inserted CloudEnabled=0 in {p}")
PY
  done
}

# Diagnostic: print the current Steam Cloud state so the operator can
# confirm the edits actually took effect. Reads files on disk; if Steam
# is running this reflects the on-disk state, NOT in-memory state.
print_cloud_state() {
  log "current Steam Cloud state on disk:"
  local f m

  # Global: registry.vdf -> CloudEnabled
  for f in "$HOME/.steam/registry.vdf" "$STEAM_HOME/registry.vdf"; do
    if [ -f "$f" ]; then
      m=$(grep -E '"CloudEnabled"[[:space:]]+"[^"]*"' "$f" | head -1)
      log "  $f: ${m:-(no CloudEnabled key)}"
    fi
  done

  # Global: config/config.vdf -> Cloud { EnableCloud }
  for f in "$STEAM_HOME/config/config.vdf" "$HOME/.steam/steam/config/config.vdf"; do
    if [ -f "$f" ]; then
      m=$(grep -E '"EnableCloud"[[:space:]]+"[^"]*"' "$f" | head -1)
      log "  $f: ${m:-(no EnableCloud key)}"
    fi
  done

  # Per-user, per-app: localconfig.vdf + sharedconfig.vdf
  local user_dir cfg root seen=()
  for root in "$STEAM_HOME/userdata" "$HOME/.steam/steam/userdata"; do
    [ -d "$root" ] || continue
    local real
    real=$(readlink -f "$root" 2>/dev/null || echo "$root")
    case " ${seen[*]} " in *" $real "*) continue ;; esac
    seen+=("$real")
    shopt -s nullglob
    for user_dir in "$root"/*/; do
      for cfg in "$user_dir/config/localconfig.vdf" "$user_dir/7/remote/sharedconfig.vdf"; do
        [ -f "$cfg" ] || continue
        m=$(python3 - "$cfg" 730 <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); appid = sys.argv[2]
src = p.read_text()
pat = re.compile(r'"' + re.escape(appid) + r'"[ \t\r\n]*\{', re.MULTILINE)
m = pat.search(src)
if not m:
    print("(no 730 block)"); sys.exit(0)
i = m.end(); depth = 1
while i < len(src) and depth > 0:
    if src[i] == '{': depth += 1
    elif src[i] == '}': depth -= 1
    i += 1
block = src[m.end():i-1]
ce = re.search(r'"cloudenabled"[ \t]+"([^"]*)"', block)
print(f'cloudenabled="{ce.group(1)}"' if ce else "(no cloudenabled key)")
PY
)
        log "  $cfg: $m"
      done
    done
    shopt -u nullglob
  done
}

# Verbose dump of everything cloud-related: file paths, sizes, mtimes,
# the actual VDF blocks our edits target, and the tail of Steam's log
# filtered to "cloud" lines. Use this to confirm whether our edits stuck
# and whether Steam saw them.
print_cloud_debug() {
  local f roots root user_dir cfg seen=()

  say "registry.vdf  (HKCU/Software/Valve/Steam/CloudEnabled)"
  for f in "$HOME/.steam/registry.vdf" "$STEAM_HOME/registry.vdf"; do
    if [ -f "$f" ]; then
      log "$f  ($(stat -c '%s bytes, mtime=%y' "$f"))"
      grep -nE '"CloudEnabled"' "$f" | sed 's/^/    /' || log "    (no CloudEnabled key)"
    else
      log "$f  (does not exist)"
    fi
  done

  say "config.vdf  (InstallConfigStore/Software/Valve/Steam/Cloud)"
  for f in "$STEAM_HOME/config/config.vdf" "$HOME/.steam/steam/config/config.vdf"; do
    if [ -f "$f" ]; then
      log "$f  ($(stat -c '%s bytes, mtime=%y' "$f"))"
      # Print the Cloud block (3 lines after first match).
      awk '
        /"Cloud"[[:space:]]*$/ { print; getline; print; in_cloud=1; depth=0; next }
        in_cloud {
          print
          for (i=1;i<=length($0);i++) {
            c = substr($0,i,1)
            if (c == "{") depth++
            else if (c == "}") { depth--; if (depth<=0) { in_cloud=0; exit } }
          }
        }
      ' "$f" | sed 's/^/    /'
    else
      log "$f  (does not exist)"
    fi
  done

  say "userdata: localconfig.vdf + sharedconfig.vdf  (apps/730/cloudenabled)"
  roots=("$STEAM_HOME/userdata" "$HOME/.steam/steam/userdata")
  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue
    local real
    real=$(readlink -f "$root" 2>/dev/null || echo "$root")
    case " ${seen[*]} " in *" $real "*) continue ;; esac
    seen+=("$real")
    log "scanning $root  (-> $real)"
    shopt -s nullglob
    for user_dir in "$root"/*/; do
      log "  SteamID dir: $user_dir"
      for cfg in "$user_dir/config/localconfig.vdf" "$user_dir/7/remote/sharedconfig.vdf"; do
        if [ -f "$cfg" ]; then
          log "    $cfg  ($(stat -c '%s bytes, mtime=%y' "$cfg"))"
          # Print the 730 block.
          python3 - "$cfg" 730 <<'PY' | sed 's/^/        /'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); appid = sys.argv[2]
src = p.read_text()
pat = re.compile(r'"' + re.escape(appid) + r'"[ \t\r\n]*\{', re.MULTILINE)
m = pat.search(src)
if not m:
    print(f"(no {appid} block in {p.name})")
    sys.exit(0)
i = m.end(); depth = 1
while i < len(src) and depth > 0:
    if src[i] == '{': depth += 1
    elif src[i] == '}': depth -= 1
    i += 1
print(src[m.start():i])
PY
        else
          log "    $cfg  (does not exist)"
        fi
      done
    done
    shopt -u nullglob
  done

  say "Steam log: cloud-related lines (last 30)"
  local logf
  for logf in "$STEAM_HOME/logs/console-linux.txt" "$STEAM_HOME/logs/cloud_log.txt"; do
    if [ -f "$logf" ]; then
      log "$logf:"
      grep -iE 'cloud|sharedconfig|localconfig' "$logf" | tail -30 | sed 's/^/    /' \
        || log "    (no cloud lines)"
    else
      log "$logf  (does not exist)"
    fi
  done

  say "running Steam processes"
  pgrep -af 'ubuntu12_32/steam|steam\.sh|steamwebhelper|/linuxsteamrt64/cs2' \
    | sed 's/^/    /' || log "    (none)"
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
  dump_log "$LOG_DIR/steam.log"
  dump_log "$STEAM_HOME/logs/console-linux.txt" 30
  return 1
}
