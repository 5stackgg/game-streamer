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

# Install or update CS2 via steamcmd directly into the configured library.
# Skips when an appmanifest already exists (idempotent fast path); set
# CS2_FORCE_UPDATE=1 to force a re-validate.
#
# Runs against $STEAM_LIBRARY (not the default ~/.local/share/Steam) by
# passing +force_install_dir, so the install lands inside our registered
# library folder and Steam picks it up on launch — no Install UI dialog.
#
# Steam should be OFF when this runs (we kill it in setup-steam before
# calling). steamcmd and Steam can clash on appmanifest writes otherwise.
install_cs2_via_steamcmd() {
  require_env STEAM_USER STEAM_PASSWORD

  local manifest="$STEAM_LIBRARY/steamapps/appmanifest_730.acf"
  local cs2_bin="$CS2_DIR/game/bin/linuxsteamrt64/cs2"

  if [ "${CS2_FORCE_UPDATE:-0}" != "1" ] \
     && [ -f "$manifest" ] && [ -x "$cs2_bin" ]; then
    local bid
    bid=$(grep -oE '"buildid"[[:space:]]+"[0-9]+"' "$manifest" | head -1 || true)
    log "CS2 already installed at $CS2_DIR (${bid:-buildid unknown}) — skip steamcmd"
    log "  force re-validate with CS2_FORCE_UPDATE=1"
    return 0
  fi

  if ! command -v /opt/steamcmd/steamcmd.sh >/dev/null 2>&1 \
       && [ ! -x /opt/steamcmd/steamcmd.sh ]; then
    die "steamcmd not found at /opt/steamcmd/steamcmd.sh — image needs the steamcmd install layer"
  fi

  # Only emit the download status when we're actually downloading.
  # Pre-cached pods returned above and never light up "Downloading CS2"
  # in the UI. status-reporter is a no-op when not configured.
  report_status status=downloading_cs2

  log "running steamcmd: install/update CS2 (appid 730) into $CS2_DIR"
  log "  this is a ~57 GB download on a fresh install"
  mkdir -p "$CS2_DIR"

  # Call steamcmd.sh directly — the /usr/local/bin/steamcmd shim resolves
  # its own dir wrong via symlink and can't find linux32/.
  /opt/steamcmd/steamcmd.sh \
    +@sSteamCmdForcePlatformType linux \
    +force_install_dir "$CS2_DIR" \
    +login "$STEAM_USER" "$STEAM_PASSWORD" \
    +app_update 730 validate \
    +quit

  if [ ! -f "$manifest" ] && [ -f "$CS2_DIR/steamapps/appmanifest_730.acf" ]; then
    # steamcmd put the manifest inside the install dir; lift it to the
    # library root where Steam expects it.
    mv "$CS2_DIR/steamapps/appmanifest_730.acf" "$manifest"
    rmdir "$CS2_DIR/steamapps" 2>/dev/null || true
    sed -i 's|"installdir"[[:space:]]*"[^"]*"|"installdir"\t\t"Counter-Strike Global Offensive"|' \
      "$manifest"
    log "  lifted manifest to $manifest"
  fi

  if [ -f "$manifest" ]; then
    local bid
    bid=$(grep -oE '"buildid"[[:space:]]+"[0-9]+"' "$manifest" | head -1 || true)
    log "CS2 install OK — ${bid:-buildid unknown}"
  else
    die "steamcmd finished but no $manifest — install failed"
  fi
}

# Pre-download a CS2 workshop map via steamcmd. Without this, +playdemo
# on a workshop map stalls CS2 on a "Subscribe?" prompt and the demo
# never starts. Idempotent — steamcmd skips if the .vpk is already on
# disk at the expected path.
#
#   $1  workshop item id (numeric, from the demo header `workshop/<id>/...`)
download_workshop_map() {
  local id="${1:?workshop id required}"

  # steamcmd writes to $STEAM_LIBRARY/steamapps/workshop/content/730/<id>/.
  # CS2 looks there at runtime — no extra symlink required.
  local target="$STEAM_LIBRARY/steamapps/workshop/content/730/${id}"
  if compgen -G "$target/*.vpk" >/dev/null 2>&1; then
    log "workshop map ${id} already present at $target — skip download"
    return 0
  fi

  if [ ! -x /opt/steamcmd/steamcmd.sh ]; then
    warn "steamcmd missing — cannot pre-download workshop map ${id}"
    return 1
  fi

  # Creds only needed when we're actually about to call steamcmd; the
  # idempotent skip above must work in env contexts that don't have them.
  require_env STEAM_USER STEAM_PASSWORD

  log "downloading workshop map ${id} via steamcmd"
  # +force_install_dir matters: steamcmd places workshop content RELATIVE
  # to the install dir, so this gives us $STEAM_LIBRARY/steamapps/workshop/...
  /opt/steamcmd/steamcmd.sh \
    +@sSteamCmdForcePlatformType linux \
    +force_install_dir "$CS2_DIR" \
    +login "$STEAM_USER" "$STEAM_PASSWORD" \
    +workshop_download_item 730 "$id" \
    +quit \
    | sed -u 's/^/  [steamcmd] /'

  if compgen -G "$target/*.vpk" >/dev/null 2>&1; then
    log "  workshop map ${id} ready at $target"
    return 0
  fi
  warn "  workshop_download_item finished but no .vpk at $target"
  warn "  CS2 will likely show the Subscribe? prompt and stall"
  return 1
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

# ---------------------------------------------------------------------
# Case 1: existing <appid> block — flip or insert cloudenabled inside.
# ---------------------------------------------------------------------
pat = re.compile(r'(^|\n)([ \t]*)"' + re.escape(appid) + r'"[ \t\r\n]*\{', re.MULTILINE)
m = pat.search(src)
if m:
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
    # Steam writes the key as "CloudEnabled" (capitalized); historic docs
    # use lowercase. Match either, preserve case to avoid duplicates.
    ce = re.search(r'(^|\n)([ \t]*)"([Cc]loud[Ee]nabled)"[ \t]+"([^"]*)"', block)
    if ce:
        if ce.group(4) == "0":
            sys.exit(0)
        new_block = block[:ce.start()] \
            + f'{ce.group(1)}{ce.group(2)}"{ce.group(3)}"\t\t"0"' \
            + block[ce.end():]
        p.write_text(src[:brace_open + 1] + new_block + src[brace_close:])
        print(f"  {cfg_path}: flipped {ce.group(3)} to 0 in existing {appid} block")
    else:
        new_block = f'\n{indent}"CloudEnabled"\t\t"0"' + block
        p.write_text(src[:brace_open + 1] + new_block + src[brace_close:])
        print(f"  {cfg_path}: inserted CloudEnabled=0 in existing {appid} block")
    sys.exit(0)

# ---------------------------------------------------------------------
# Case 2: existing "apps" block — insert <appid> block inside.
# ---------------------------------------------------------------------
apps = re.search(r'(\n[ \t]*)"apps"[ \t\r\n]*\{', src)
if apps:
    indent = apps.group(1).rstrip("\n")
    insertion = (
        f'{indent}\t"{appid}"\n{indent}\t{{\n'
        f'{indent}\t\t"CloudEnabled"\t\t"0"\n{indent}\t}}\n'
    )
    p.write_text(src[:apps.end()] + insertion + src[apps.end():])
    print(f"  {cfg_path}: inserted new {appid} block with CloudEnabled=0")
    sys.exit(0)

# ---------------------------------------------------------------------
# Case 3: no "apps" block at all — synthesize the whole structure under
# the Steam block. sharedconfig.vdf is nearly empty before the first
# CS2 launch, so this is the case that hit you.
# ---------------------------------------------------------------------
def find_block_open(src, key, start=0):
    """Return offset right after the `{` of `"key" {` (or -1)."""
    pat = re.compile(r'"' + re.escape(key) + r'"[ \t\r\n]*\{')
    mm = pat.search(src, start)
    return mm.end() if mm else -1

sw = find_block_open(src, "Software")
if sw == -1:
    print(f"  {cfg_path}: no Software block — leaving untouched"); sys.exit(0)
valve = find_block_open(src, "Valve", sw)
if valve == -1:
    print(f"  {cfg_path}: no Valve block — leaving untouched"); sys.exit(0)
steam = find_block_open(src, "Steam", valve)
if steam == -1:
    print(f"  {cfg_path}: no Steam block — leaving untouched"); sys.exit(0)

# Pull the indent of the "Steam" line so the new block matches the file's style.
sm = re.search(r'(\n)([ \t]*)"Steam"[ \t\r\n]*\{', src[:steam])
steam_indent = sm.group(2) if sm else "\t\t\t"
inner = steam_indent + "\t"  # one level deeper for "apps"

insertion = (
    f'\n{inner}"apps"\n{inner}{{\n'
    f'{inner}\t"{appid}"\n{inner}\t{{\n'
    f'{inner}\t\t"CloudEnabled"\t\t"0"\n{inner}\t}}\n'
    f'{inner}}}'
)
p.write_text(src[:steam] + insertion + src[steam:])
print(f"  {cfg_path}: synthesized apps/{appid}/CloudEnabled=0 under Steam block")
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

# Disable the Steam in-game overlay globally by editing registry.vdf
# (HKCU/Software/Valve/Steam/EnableGameOverlay = 0). Same toggle as the
# Steam UI's Settings → In-Game → "Enable the Steam Overlay while
# in-game". Without this, Steam can pop the overlay over cs2 mid-match
# (Shift+Tab, friend invites, achievement toasts) and steal focus —
# we'd capture the overlay instead of the game.
#
# Steam rewrites registry.vdf on shutdown; call BEFORE start_steam.
disable_overlay_globally() {
  if pgrep -f '/ubuntu12_32/steam' >/dev/null 2>&1; then
    log "disable_overlay_globally: Steam is running — skip (would be clobbered on shutdown)"
    return 0
  fi
  local f
  for f in "$HOME/.steam/registry.vdf" "$STEAM_HOME/registry.vdf"; do
    [ -f "$f" ] || continue
    log "disable_overlay_globally: editing $f"
    python3 - "$f" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()

m = re.search(r'"EnableGameOverlay"[ \t\r\n]+"([^"]*)"', src)
if m:
    if m.group(1) == "0":
        print(f"  EnableGameOverlay already 0 in {p}")
        sys.exit(0)
    new = re.sub(
        r'("EnableGameOverlay"[ \t\r\n]+")[^"]*(")',
        r'\g<1>0\g<2>',
        src, count=1,
    )
    p.write_text(new)
    print(f"  flipped EnableGameOverlay to 0 in {p}")
    sys.exit(0)

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

insertion = '\n\t\t\t\t\t"EnableGameOverlay"\t\t"0"'
p.write_text(src[:steam] + insertion + src[steam:])
print(f"  inserted EnableGameOverlay=0 in {p}")
PY
  done
}

# Edit a single localconfig.vdf to set OverlayAppEnabled=0 inside the
# apps/<appid> block. Idempotent. Mirrors _vdf_disable_app_cloud's
# 3-case structure (existing key, existing app block, no apps block).
_vdf_disable_app_overlay() {
  local cfg="$1"
  [ -f "$cfg" ] || return 0
  python3 - "$cfg" 730 <<'PY'
import re, sys, pathlib

cfg_path, appid = sys.argv[1], sys.argv[2]
p = pathlib.Path(cfg_path)
src = p.read_text()

pat = re.compile(r'(^|\n)([ \t]*)"' + re.escape(appid) + r'"[ \t\r\n]*\{', re.MULTILINE)
m = pat.search(src)
if m:
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
    oe = re.search(r'(^|\n)([ \t]*)"([Oo]verlay[Aa]pp[Ee]nabled)"[ \t]+"([^"]*)"', block)
    if oe:
        if oe.group(4) == "0":
            sys.exit(0)
        new_block = block[:oe.start()] \
            + f'{oe.group(1)}{oe.group(2)}"{oe.group(3)}"\t\t"0"' \
            + block[oe.end():]
        p.write_text(src[:brace_open + 1] + new_block + src[brace_close:])
        print(f"  {cfg_path}: flipped {oe.group(3)} to 0 in existing {appid} block")
    else:
        new_block = f'\n{indent}"OverlayAppEnabled"\t\t"0"' + block
        p.write_text(src[:brace_open + 1] + new_block + src[brace_close:])
        print(f"  {cfg_path}: inserted OverlayAppEnabled=0 in existing {appid} block")
    sys.exit(0)

apps = re.search(r'(\n[ \t]*)"apps"[ \t\r\n]*\{', src)
if apps:
    indent = apps.group(1).rstrip("\n")
    insertion = (
        f'{indent}\t"{appid}"\n{indent}\t{{\n'
        f'{indent}\t\t"OverlayAppEnabled"\t\t"0"\n{indent}\t}}\n'
    )
    p.write_text(src[:apps.end()] + insertion + src[apps.end():])
    print(f"  {cfg_path}: inserted new {appid} block with OverlayAppEnabled=0")
    sys.exit(0)

def find_block_open(src, key, start=0):
    pat = re.compile(r'"' + re.escape(key) + r'"[ \t\r\n]*\{')
    mm = pat.search(src, start)
    return mm.end() if mm else -1

sw = find_block_open(src, "Software")
if sw == -1:
    print(f"  {cfg_path}: no Software block — leaving untouched"); sys.exit(0)
valve = find_block_open(src, "Valve", sw)
if valve == -1:
    print(f"  {cfg_path}: no Valve block — leaving untouched"); sys.exit(0)
steam = find_block_open(src, "Steam", valve)
if steam == -1:
    print(f"  {cfg_path}: no Steam block — leaving untouched"); sys.exit(0)

sm = re.search(r'(\n)([ \t]*)"Steam"[ \t\r\n]*\{', src[:steam])
steam_indent = sm.group(2) if sm else "\t\t\t"
inner = steam_indent + "\t"

insertion = (
    f'\n{inner}"apps"\n{inner}{{\n'
    f'{inner}\t"{appid}"\n{inner}\t{{\n'
    f'{inner}\t\t"OverlayAppEnabled"\t\t"0"\n{inner}\t}}\n'
    f'{inner}}}'
)
p.write_text(src[:steam] + insertion + src[steam:])
print(f"  {cfg_path}: synthesized apps/{appid}/OverlayAppEnabled=0 under Steam block")
PY
}

# Disable Steam overlay for CS2 in every user's localconfig.vdf. Mirrors
# disable_cs2_cloud — Steam clobbers localconfig.vdf on shutdown, so
# this is a no-op while Steam is running. Call BEFORE start_steam.
disable_cs2_overlay() {
  if pgrep -f '/ubuntu12_32/steam' >/dev/null 2>&1; then
    log "disable_cs2_overlay: Steam is running — skip (would be clobbered on shutdown)"
    return 0
  fi

  local roots=("$STEAM_HOME/userdata" "$HOME/.steam/steam/userdata")
  local seen=() root user_dir steamid edited=0
  for root in "${roots[@]}"; do
    [ -d "$root" ] || continue
    local real
    real=$(readlink -f "$root" 2>/dev/null || echo "$root")
    case " ${seen[*]} " in *" $real "*) continue ;; esac
    seen+=("$real")

    shopt -s nullglob
    for user_dir in "$root"/*/; do
      steamid=$(basename "$user_dir")
      case "$steamid" in ''|*[!0-9]*) continue ;; esac
      log "disable_cs2_overlay: SteamID $steamid (under $root)"
      _vdf_disable_app_overlay "$user_dir/config/localconfig.vdf"
      _vdf_disable_overlay_system "$user_dir/config/localconfig.vdf"
      edited=1
    done
    shopt -u nullglob
  done

  [ "$edited" = 0 ] && log "disable_cs2_overlay: no userdata SteamIDs found yet — skip"
  return 0
}

# The per-app `OverlayAppEnabled=0` only suppresses the overlay panel
# inside cs2 — Steam still spawns GameOverlayUI and pops the "Press
# Shift+Tab to begin" first-run toast over the captured stream. The
# master switch is `system.EnableGameOverlay` in localconfig.vdf
# (mirrors Settings → In-Game → "Enable the Steam Overlay while
# in-game"). With this flipped to 0, GameOverlayUI never spawns and
# the toast never appears.
_vdf_disable_overlay_system() {
  local cfg="$1"
  [ -f "$cfg" ] || return 0
  python3 - "$cfg" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()

# Find or create the top-level "system" block inside UserLocalConfigStore.
sys_pat = re.compile(r'(^|\n)([ \t]*)"system"[ \t\r\n]*\{', re.MULTILINE)
sm = sys_pat.search(src)
if sm:
    brace_open = sm.end() - 1
    depth, i = 1, brace_open + 1
    while i < len(src) and depth > 0:
        if src[i] == '{': depth += 1
        elif src[i] == '}': depth -= 1
        i += 1
    if depth != 0:
        print(f"  {p}: unbalanced braces in system block — refusing to edit")
        sys.exit(1)
    brace_close = i - 1
    block = src[brace_open + 1:brace_close]
    indent = sm.group(2) + "\t"
    eg = re.search(r'(^|\n)([ \t]*)"([Ee]nable[Gg]ame[Oo]verlay)"[ \t]+"([^"]*)"', block)
    if eg:
        if eg.group(4) == "0":
            sys.exit(0)
        new_block = block[:eg.start()] \
            + f'{eg.group(1)}{eg.group(2)}"{eg.group(3)}"\t\t"0"' \
            + block[eg.end():]
        p.write_text(src[:brace_open + 1] + new_block + src[brace_close:])
        print(f"  {p}: flipped system.{eg.group(3)} to 0")
    else:
        new_block = f'\n{indent}"EnableGameOverlay"\t\t"0"' + block
        p.write_text(src[:brace_open + 1] + new_block + src[brace_close:])
        print(f"  {p}: inserted system.EnableGameOverlay=0")
    sys.exit(0)

# No system block — synthesize one at the top-level.
root = re.match(r'\s*"UserLocalConfigStore"[ \t\r\n]*\{', src)
if not root:
    print(f"  {p}: no UserLocalConfigStore root — leaving untouched")
    sys.exit(0)
insertion = '\n\t"system"\n\t{\n\t\t"EnableGameOverlay"\t\t"0"\n\t}'
p.write_text(src[:root.end()] + insertion + src[root.end():])
print(f"  {p}: synthesized system.EnableGameOverlay=0")
PY
}

# Diagnostic: print the current Steam overlay state on disk.
print_overlay_state() {
  log "current Steam overlay state on disk:"
  local f m

  for f in "$HOME/.steam/registry.vdf" "$STEAM_HOME/registry.vdf"; do
    if [ -f "$f" ]; then
      m=$(grep -E '"EnableGameOverlay"[[:space:]]+"[^"]*"' "$f" | head -1)
      log "  $f: ${m:-(no EnableGameOverlay key)}"
    fi
  done

  local user_dir cfg root seen=()
  for root in "$STEAM_HOME/userdata" "$HOME/.steam/steam/userdata"; do
    [ -d "$root" ] || continue
    local real
    real=$(readlink -f "$root" 2>/dev/null || echo "$root")
    case " ${seen[*]} " in *" $real "*) continue ;; esac
    seen+=("$real")
    shopt -s nullglob
    for user_dir in "$root"/*/; do
      cfg="$user_dir/config/localconfig.vdf"
      [ -f "$cfg" ] || continue
      m=$(python3 - "$cfg" 730 <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); appid = sys.argv[2]
src = p.read_text()
parts = []
# Per-app
pat = re.compile(r'"' + re.escape(appid) + r'"[ \t\r\n]*\{', re.MULTILINE)
m = pat.search(src)
if m:
    i = m.end(); depth = 1
    while i < len(src) and depth > 0:
        if src[i] == '{': depth += 1
        elif src[i] == '}': depth -= 1
        i += 1
    block = src[m.end():i-1]
    oe = re.search(r'"([Oo]verlay[Aa]pp[Ee]nabled)"[ \t]+"([^"]*)"', block)
    parts.append(f'{oe.group(1)}="{oe.group(2)}"' if oe else "(no OverlayAppEnabled key)")
else:
    parts.append("(no 730 block)")
# System (master switch)
sys_pat = re.compile(r'"system"[ \t\r\n]*\{', re.MULTILINE)
sm = sys_pat.search(src)
if sm:
    i = sm.end(); depth = 1
    while i < len(src) and depth > 0:
        if src[i] == '{': depth += 1
        elif src[i] == '}': depth -= 1
        i += 1
    block = src[sm.end():i-1]
    eg = re.search(r'"([Ee]nable[Gg]ame[Oo]verlay)"[ \t]+"([^"]*)"', block)
    parts.append(f'{eg.group(1)}="{eg.group(2)}"' if eg else "(no system.EnableGameOverlay key)")
else:
    parts.append("(no system block)")
print(" | ".join(parts))
PY
)
      log "  $cfg: $m"
    done
    shopt -u nullglob
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
ce = re.search(r'"([Cc]loud[Ee]nabled)"[ \t]+"([^"]*)"', block)
print(f'{ce.group(1)}="{ce.group(2)}"' if ce else "(no CloudEnabled key)")
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

# Comprehensive diagnostic dump — everything we need to figure out why
# Steam isn't behaving. One command, all signals.
print_full_debug() {
  say "ENVIRONMENT"
  log "DISPLAY=$DISPLAY"
  log "HOME=$HOME"
  log "STEAM_HOME=$STEAM_HOME"
  log "STEAM_LIBRARY=$STEAM_LIBRARY"
  log "CS2_DIR=$CS2_DIR"
  log "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
  log "STATE_DIR=$LOG_DIR (logs stream to k8s pod stdout/stderr)"
  log "uid=$(id -u) euid=$(id -u) user=$(id -un)"
  log "container hostname: $(hostname 2>/dev/null)"

  say "STEAM PROCESSES"
  pgrep -af 'steam\.sh|ubuntu12_32/steam|ubuntu12_64|steamwebhelper|dbus-launch|/linuxsteamrt64/cs2|pressure-vessel|srt-bwrap|/steamcmd' \
    | sed 's/^/  /' || log "  (none)"

  say "STEAM PIPE"
  if [ -p "$HOME/.steam/steam.pipe" ]; then
    log "  $HOME/.steam/steam.pipe exists"
  else
    log "  $HOME/.steam/steam.pipe MISSING"
  fi
  if [ -f "$HOME/.steam/steam.pid" ]; then
    local spid
    spid=$(cat "$HOME/.steam/steam.pid" 2>/dev/null)
    log "  $HOME/.steam/steam.pid = $spid (alive=$(kill -0 "$spid" 2>/dev/null && echo yes || echo no))"
  else
    log "  $HOME/.steam/steam.pid MISSING"
  fi

  say "STEAM SDK / steamclient.so"
  for f in "$HOME/.steam/sdk32/steamclient.so" "$HOME/.steam/sdk64/steamclient.so"; do
    if [ -L "$f" ]; then
      log "  $f -> $(readlink "$f")  (resolved: $(readlink -f "$f" 2>/dev/null))"
    elif [ -f "$f" ]; then
      log "  $f (regular file, $(stat -c '%s' "$f") bytes)"
    else
      log "  $f MISSING"
    fi
  done

  say "STEAM BINARIES"
  for b in \
    "$STEAM_HOME/steam.sh" \
    "$STEAM_HOME/ubuntu12_32/steam" \
    "$STEAM_HOME/ubuntu12_64/steamwebhelper"; do
    if [ -x "$b" ]; then
      log "  $b (exec, $(stat -c '%s' "$b") bytes)"
    elif [ -e "$b" ]; then
      log "  $b (NOT executable)"
    else
      log "  $b MISSING"
    fi
  done

  say "STEAM HOME OWNERSHIP / PERMS  (root-cause debugging)"
  log "  $STEAM_HOME (symlink itself):"
  ls -lad "$STEAM_HOME" 2>/dev/null | sed 's/^/    /' || log "    MISSING"
  # Resolve through any symlink so we see the actual contents.
  local resolved
  resolved=$(readlink -f "$STEAM_HOME" 2>/dev/null)
  if [ -n "$resolved" ] && [ "$resolved" != "$STEAM_HOME" ]; then
    log "  resolved: $resolved"
  fi
  log "  $STEAM_HOME/ (top-level contents — following symlink):"
  ls -laL "$STEAM_HOME" 2>/dev/null | head -40 | sed 's/^/    /' || log "    (cannot read)"
  log "  $STEAM_HOME/package/:"
  ls -la  "$STEAM_HOME/package/" 2>/dev/null | head -15 | sed 's/^/    /' \
    || log "    (does not exist — Steam recreates on first start)"
  log "  $STEAM_HOME/package/tmp/ (interrupted-update marker):"
  ls -la  "$STEAM_HOME/package/tmp/" 2>/dev/null | head -10 | sed 's/^/    /' \
    || log "    (no tmp — clean state)"
  log "  /tmp/steam_pipe_*, /tmp/dumps* (cross-pod leftovers):"
  ls -la  /tmp/steam_pipe_* /tmp/dumps* 2>/dev/null | head -10 | sed 's/^/    /' \
    || log "    (none)"
  log "  $STEAM_HOME/package/steam_client_ubuntu12*  (manifest + interrupted markers):"
  ls -la "$STEAM_HOME/package"/steam_client_ubuntu12* 2>/dev/null | sed 's/^/    /' \
    || log "    (none — fresh state)"
  log "  $STEAM_HOME/.crash, .steam.start, .steamstart.id (lock markers):"
  ls -la "$STEAM_HOME/.crash" "$STEAM_HOME/.steam.start" "$STEAM_HOME/.steamstart.id" \
    2>/dev/null | sed 's/^/    /' \
    || log "    (none)"

  say "STEAM RUNTIME"
  for d in \
    "$STEAM_HOME/ubuntu12_32/steam-runtime" \
    "$STEAM_HOME/steamrt64/pv-runtime" \
    "$STEAM_HOME/linux64"; do
    if [ -d "$d" ]; then
      log "  $d  ($(find "$d" -maxdepth 1 -type f 2>/dev/null | wc -l) files at top level)"
    else
      log "  $d MISSING"
    fi
  done

  say "32-BIT LIB AVAILABILITY  (steamui.so dlmopen failure debugging)"
  log "  Steam's UI is 32-bit and dlmopen()s these libs in a fresh"
  log "  linker namespace; LD_LIBRARY_PATH isn't honored, so the system"
  log "  must have the i386 versions installed (in /usr/lib/i386-linux-gnu)."
  local lib
  for lib in libgobject-2.0.so.0 libglib-2.0.so.0 libgtk-x11-2.0.so.0 \
             libpango-1.0.so.0 libpangocairo-1.0.so.0 libcairo.so.2 \
             libgdk_pixbuf-2.0.so.0 libatk-1.0.so.0; do
    if [ -f "/usr/lib/i386-linux-gnu/$lib" ]; then
      log "  /usr/lib/i386-linux-gnu/$lib  OK"
    else
      log "  /usr/lib/i386-linux-gnu/$lib  MISSING"
    fi
  done
  log "  installed i386 packages (Steam-relevant):"
  dpkg -l 2>/dev/null \
    | grep ':i386' \
    | grep -E 'glib|gtk|pango|cairo|gdk|atk|xml|xslt' \
    | awk '{print "    " $2 " " $3}' \
    | head -20 \
    || log "    (dpkg unavailable or none installed)"

  say "USER NAMESPACES (Steam needs unprivileged user-ns for bwrap sandbox)"
  if unshare -U /bin/true 2>/dev/null; then
    log "  unshare -U works — user namespaces are enabled"
  else
    log "  unshare -U FAILED — user namespaces DISABLED (Steam will hang)"
  fi
  if [ -r /proc/sys/user/max_user_namespaces ]; then
    log "  max_user_namespaces = $(cat /proc/sys/user/max_user_namespaces)"
  fi
  if [ -r /proc/sys/kernel/unprivileged_userns_clone ]; then
    log "  unprivileged_userns_clone = $(cat /proc/sys/kernel/unprivileged_userns_clone)"
  fi
  if [ -r /proc/self/status ]; then
    log "  CapEff: $(grep '^CapEff' /proc/self/status 2>/dev/null)"
  fi

  say "X SERVER"
  if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
    log "  display $DISPLAY is up"
  else
    log "  display $DISPLAY DOWN"
  fi

  say "X WINDOWS"
  if command -v list_x_windows >/dev/null 2>&1; then
    list_x_windows
  fi

  say "STEAM LOGS (tail of each on-disk log Steam writes)"
  # Process stdout/stderr (steam, xorg, openbox) all go to the k8s pod
  # log already — `kubectl logs` shows them in chronological order. The
  # files below are written by Steam itself, not us, so they're not in
  # the container log; tail them inline.
  local logf
  for logf in \
    "$STEAM_HOME/logs/console-linux.txt" \
    "$STEAM_HOME/logs/stderr.txt" \
    "$STEAM_HOME/logs/bootstrap_log.txt" \
    "$STEAM_HOME/logs/cef_log.txt" \
    "$STEAM_HOME/logs/webhelper-linux.txt" \
    "$STEAM_HOME/logs/cloud_log.txt"; do
    if [ -f "$logf" ]; then
      log "--- $logf (last 60 lines) ---"
      tail -60 "$logf" | sed 's/^/    /'
    fi
  done

  say "CRASH DUMPS"
  ls -la /tmp/dumps* /tmp/source_engine_*.lock /mnt/game-streamer/steam/.crash 2>/dev/null \
    | sed 's/^/  /' || log "  (none)"

  say "CS2 INSTALL"
  log "  $STEAM_LIBRARY/steamapps/appmanifest_730.acf:"
  if [ -f "$STEAM_LIBRARY/steamapps/appmanifest_730.acf" ]; then
    grep -E '"(buildid|installdir|StateFlags|name)"' \
      "$STEAM_LIBRARY/steamapps/appmanifest_730.acf" | sed 's/^/    /'
  else
    log "    MISSING"
  fi
  log "  $CS2_DIR/game/bin/linuxsteamrt64/cs2:"
  if [ -x "$CS2_DIR/game/bin/linuxsteamrt64/cs2" ]; then
    log "    exec ($(stat -c '%s' "$CS2_DIR/game/bin/linuxsteamrt64/cs2") bytes)"
  else
    log "    MISSING or not executable"
  fi

  say "CLOUD STATE"
  print_cloud_state

  say "DISK USAGE"
  df -h /mnt/game-streamer / "$STEAM_HOME" 2>/dev/null | sed 's/^/  /' || true
}

# Fix the persisted-state ownership/permissions bug that prevents Steam
# from creating its update cache.
#
# Symptom: bootstrap_log.txt repeats:
#   Error: Couldn't create cache directory /root/.local/share/Steam/package, got error 13
#   Shutdown
# Steam shuts down before webhelper spawns → no UI ever appears.
#
# Root cause: $STEAM_HOME is host-mounted, and at some point a process
# running as a different uid (we saw 1000:1000 on the leftover .crash
# file) wrote to it. Steam's pressure-vessel sandbox now can't write
# the package dir under whatever effective uid bwrap maps it to.
#
# The package dir is Steam's update cache — safe to nuke; Steam
# recreates it on next start.
# Make $STEAM_HOME a symlink into the cache mount so Steam's state
# persists across pod restarts WITHOUT a second bind mount on
# $STEAM_HOME (which would create EXDEV on Steam self-update — see
# fix_steam_perms for the failure mode). After this:
#   /root/.local/share/Steam   ->   /mnt/game-streamer/steam
# Steam reads/writes via the canonical $HOME path; everything resolves
# to one filesystem (the cache mount), so rename(2) always succeeds.
#
# On first ever run we migrate any pre-existing $STEAM_HOME content
# into the target. If both have content (e.g. a prior pod populated
# the cache and a new pod's image dropped a fresh empty Steam dir),
# the persisted cache wins.
ensure_steam_home_persist() {
  local target="$STEAM_LIBRARY/steam"
  mkdir -p "$target"

  if [ -L "$STEAM_HOME" ] \
     && [ "$(readlink -f "$STEAM_HOME" 2>/dev/null)" = "$(readlink -f "$target" 2>/dev/null)" ]; then
    log "ensure_steam_home_persist: $STEAM_HOME already -> $target"
    return 0
  fi

  if [ -L "$STEAM_HOME" ]; then
    log "ensure_steam_home_persist: replacing wrong symlink ($STEAM_HOME -> $(readlink "$STEAM_HOME"))"
    rm -f "$STEAM_HOME"
  elif [ -d "$STEAM_HOME" ]; then
    if [ -z "$(ls -A "$target" 2>/dev/null)" ]; then
      log "ensure_steam_home_persist: migrating $STEAM_HOME contents -> $target"
      cp -a "$STEAM_HOME/." "$target/" 2>/dev/null || true
    else
      log "ensure_steam_home_persist: cache already populated, dropping ephemeral $STEAM_HOME"
    fi
    rm -rf "$STEAM_HOME"
  fi

  mkdir -p "$(dirname "$STEAM_HOME")"
  ln -sfn "$target" "$STEAM_HOME"
  log "ensure_steam_home_persist: $STEAM_HOME -> $target"
}

fix_steam_perms() {
  if pgrep -f '/ubuntu12_32/steam' >/dev/null 2>&1; then
    log "fix_steam_perms: Steam is running — skip"
    return 0
  fi

  # Legacy `$STEAM_HOME/steam` symlink that points to /mnt/game-streamer/steam.
  # That target is a *different bind mount* from $STEAM_HOME, so rename(2)
  # across the symlink boundary fails with EXDEV. Steam's self-update
  # uses rename to commit `package/tmp/.../steam/cached/X` -> `./steam/cached/X`,
  # which crosses the mount and dies with:
  #   BCommitUpdatedFiles: failed to rename ... (error 18)
  #   Failed to apply update, reverting...
  #   dlmopen steamui.so failed: ... no such file
  # — Steam exits before webhelper spawns. Removing the symlink lets Steam
  # create ./steam/ as a real subdir on the same mount, so renames work.
  if [ -L "$STEAM_HOME/steam" ]; then
    log "fix_steam_perms: removing legacy $STEAM_HOME/steam symlink (-> $(readlink "$STEAM_HOME/steam"))"
    rm -f "$STEAM_HOME/steam"
  fi

  # Steam's update working area. Two distinct things live under package/:
  #   * package/steam_client_ubuntu12_*.zip + .manifest — completed,
  #     immutable downloads from the client-update CDN. Safe to keep
  #     across crashes; reusing them lets Steam skip a ~45s redownload.
  #   * package/tmp/                                    — half-extracted
  #     staging area for an in-progress update. If the prior process
  #     died mid-rename this can be inconsistent and will corrupt the
  #     next update attempt.
  #
  # Pods in our deployment get SIGKILL'd on stop, so Steam never exits
  # cleanly and a `.crash` marker shows up on every restart. That makes
  # `.crash` an unreliable signal of update corruption — wiping the
  # whole package/ on every boot would force a redownload on every
  # cold-ish start. Only `package/tmp/` presence is a direct, reliable
  # signal of a half-applied update; nuke just that.
  #
  # FORCE_PACKAGE_RESET=1 still wipes the whole package/ dir as a
  # manual escape hatch when a download is genuinely corrupt.
  if [ "${FORCE_PACKAGE_RESET:-0}" = "1" ]; then
    if [ -e "$STEAM_HOME/package" ]; then
      log "fix_steam_perms: FORCE_PACKAGE_RESET=1 — removing $STEAM_HOME/package"
      rm -rf "$STEAM_HOME/package"
    fi
  elif [ -e "$STEAM_HOME/package/tmp" ]; then
    log "fix_steam_perms: package/tmp present — removing only $STEAM_HOME/package/tmp (cache preserved)"
    rm -rf "$STEAM_HOME/package/tmp"
  fi

  # Stale lock/pid leftovers can wedge Steam at startup.
  rm -f "$STEAM_HOME/.steamstart.id" \
        "$STEAM_HOME/.steam.start" \
        "$STEAM_HOME/.crash" \
        "$STEAM_LIBRARY/steam/.crash" 2>/dev/null || true

  # Normalize ownership across the ENTIRE Steam home. Slow on warm
  # boots (recurses ~10k files in the cache mount) but only matters
  # the FIRST time a fresh host volume is mounted — once everything
  # is root:root, subsequent boots can skip. Marker file `.perms-ok`
  # records that we've done it. Bypass the skip by removing the
  # marker or setting FORCE_FIX_STEAM_PERMS=1.
  #
  # IMPORTANT: -H. Without it, $STEAM_HOME (a symlink to the cache
  # mount) is NOT traversed — we'd be no-op'ing on the symlink itself
  # and never touching the contents. With -H, chown follows
  # command-line symlinks for the recursion. Same for chmod.
  # CS2_DIR is on a separate path ($STEAM_LIBRARY/steamapps/...), not
  # affected — and it's 60GB so we wouldn't want to chown it anyway.
  local perms_marker="$STEAM_HOME/.perms-ok"
  if [ "${FORCE_FIX_STEAM_PERMS:-0}" != "1" ] && [ -f "$perms_marker" ]; then
    log "fix_steam_perms: marker present at $perms_marker — skip chown/chmod"
  else
    log "fix_steam_perms: chown -RH root:root + chmod -RH u+rwX on $STEAM_HOME"
    chown -RH root:root "$STEAM_HOME" 2>/dev/null || true
    chmod -RH u+rwX     "$STEAM_HOME" 2>/dev/null || true
    touch "$perms_marker" 2>/dev/null || true
  fi
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
# debug stream and complete any 2FA/captcha. Steam's stdout/stderr are
# tagged [steam] and stream to the k8s pod log via spawn_logged.
start_steam() {
  require_env STEAM_USER STEAM_PASSWORD

  if steam_pipe_up; then
    log "steam already running (pid $(cat "$HOME/.steam/steam.pid"))"
    return 0
  fi

  ensure_steam_bootstrap
  restore_real_steamclient

  # Webhelper bootstrap dominates cold-boot wall time (~50-60s on a
  # warm cache). These flags drop subsystems we never use:
  #
  #   -nofriendsui    skip Friends UI initialisation
  #   -nochatui       skip Chat UI initialisation
  #   -no-browser     skip the in-Steam web browser
  #
  # All three are community-known and safe — they don't affect the
  # webhelper paths +applaunch goes through. We deliberately do NOT
  # use -silent (tested earlier — it suppresses the webhelper subset
  # that handles +applaunch and cs2 never spawned).
  #
  # Override with STEAM_LAUNCH_FLAGS="" to fall back to a vanilla
  # launch if any of these ever turn out to break a future Steam
  # update.
  : "${STEAM_LAUNCH_FLAGS:=-nofriendsui -nochatui -no-browser}"
  # shellcheck disable=SC2206  # intentional word-split into argv
  local extra_flags=( $STEAM_LAUNCH_FLAGS )

  log "launching Steam with login=$STEAM_USER (flags: $STEAM_LAUNCH_FLAGS)"
  spawn_logged steam stdbuf -oL -eL dbus-launch --exit-with-session \
    "$STEAM_HOME/steam.sh" \
      "${extra_flags[@]}" \
      -login "$STEAM_USER" "$STEAM_PASSWORD"
  log "  steam wrapper pid=$SPAWNED_PID"
}

# Wait for Steam to finish login by polling for the userdata
# directory. With `-silent` no window ever appears, so we can't proxy
# the "logged in" signal off window visibility — userdata/<steamid>/
# is what actually indicates a completed login + roaming-config sync.
#
# On warm boots (HAD_USERDATA=1) this returns immediately. On cold
# first-boots it takes 30-60s (steamwebhelper has to fetch + sync).
wait_for_steam_userdata() {
  # Waits indefinitely — operator cancels by closing the popup.
  # "timeout" arg accepted for callsite compatibility, treated as
  # no-op.
  log "waiting for steam userdata (login + roaming config)"
  local i=0
  while :; do
    if [ -d "$STEAM_HOME/userdata" ]; then
      local found
      found=$(find "$STEAM_HOME/userdata" -mindepth 1 -maxdepth 1 -type d \
        ! -name anonymous 2>/dev/null | head -1)
      if [ -n "$found" ]; then
        log "  userdata up after ${i}s ($found)"
        return 0
      fi
    fi
    i=$(( i + 1 ))
    [ $(( i % 15 )) -eq 0 ] && log "  still waiting (${i}s)"
    sleep 1
  done
}

# Wait for Steam IPC to come up. Waits indefinitely — operator
# cancels by closing the popup window (which drops the WS, which
# tells the api to delete the pod). No need for a self-imposed
# timeout that just bricks the pod with no recovery path.
#
# A "timeout" arg is still accepted but treated as a no-op so callers
# can keep their old signatures.
wait_for_steam_pipe() {
  log "waiting for steam pipe (Ctrl-C / pod delete to cancel)"
  local i=0
  while :; do
    if steam_pipe_up; then
      log "  PIPE UP after ${i}s (pid $(cat "$HOME/.steam/steam.pid"))"
      return 0
    fi
    i=$(( i + 1 ))
    if [ $(( i % 15 )) -eq 0 ]; then
      log "  still waiting (${i}s)"
    fi
    sleep 1
  done
}
