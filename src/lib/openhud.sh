# shellcheck shell=bash
# OpenHud (CS2 spectator HUD) helpers. The HUD is an Electron app that
# runs an Express+Socket.io server on $OPENHUD_PORT (default 1349) and
# renders a transparent BrowserWindow loading http://localhost:$PORT/api/hud
# directly on the X display. We start it on the same Xorg-dummy that CS2
# is on, so ximagesrc captures CS2 + the HUD overlay together — viewers
# of hls.5stack.gg/<match-id>/ see them composited.
#
# Requires:
#   * picom running (otherwise transparent background blends as black on
#     openbox)
#   * an X display already up (start_xorg)
#   * /opt/openhud/openhud (Electron-builder unpacked binary, dropped in
#     by the Dockerfile via OPENHUD_TARBALL_URL)
#
# All ops idempotent.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${OPENHUD_BIN:=/opt/openhud/openhud}"
: "${OPENHUD_PORT:=1349}"
: "${OPENHUD_HOST:=127.0.0.1}"
: "${OPENHUD_USERDATA:=$HOME/.config/openhud}"
: "${OPENHUD_GSI_TOKEN:=5stack}"
: "${OPENHUD_OVERLAY_W:=1920}"
: "${OPENHUD_OVERLAY_H:=1080}"
# 5stack API base for seeding match metadata. API_TOKEN optional — if set
# we send it as a Bearer auth header.
: "${API_BASE:=}"
: "${API_TOKEN:=}"

export OPENHUD_BIN OPENHUD_PORT OPENHUD_HOST OPENHUD_USERDATA \
       OPENHUD_GSI_TOKEN OPENHUD_OVERLAY_W OPENHUD_OVERLAY_H

# ---- picom ---------------------------------------------------------------
picom_running() { pgrep -x picom >/dev/null 2>&1; }

# Start picom in --daemon mode using the xrender backend. xrender works on
# Xorg-dummy without GLX shenanigans; switch to --backend glx if artifacts
# show up. Bare picom (no config file) — we only need compositing, not
# fancy effects.
start_picom() {
  if picom_running; then
    log "picom already up"
    return 0
  fi
  log "starting picom"
  spawn_logged picom picom --backend xrender --no-fading-openclose --daemon
  local i
  for i in $(seq 1 20); do
    picom_running && { log "  picom up"; return 0; }
    sleep 0.2
  done
  warn "picom didn't come up — HUD overlay will composite as opaque black (see [picom] log lines above)"
  return 1
}

stop_picom() { pkill -x picom 2>/dev/null || true; }

# ---- openhud server ------------------------------------------------------
openhud_running() { pgrep -f "$OPENHUD_BIN" >/dev/null 2>&1; }

openhud_server_up() {
  # Probe the root URL and accept any HTTP response. We previously hit
  # /api/hud with `curl -f`, but that returns non-2xx until the HUD
  # overlay window has actually been opened — making us declare the
  # server "down" even when Express is fully up and serving. Any HTTP
  # status (including 404) means the server is listening and responding,
  # which is what we actually care about.
  local code
  code=$(curl -sS -o /dev/null --max-time 2 -w '%{http_code}' \
    "http://${OPENHUD_HOST}:${OPENHUD_PORT}/" 2>/dev/null)
  [ -n "$code" ] && [ "$code" != "000" ]
}

start_openhud() {
  if [ ! -x "$OPENHUD_BIN" ]; then
    warn "OpenHud binary not found at $OPENHUD_BIN — skipping HUD overlay"
    warn "  the openhud-builder stage in Dockerfile should have populated this;"
    warn "  rebuild the image and check the build logs for 'dist:linux' errors"
    return 1
  fi
  if openhud_running; then
    log "openhud already running"
    return 0
  fi
  mkdir -p "$OPENHUD_USERDATA"
  log "starting openhud ($OPENHUD_BIN)"
  # --no-sandbox is required for Electron-as-root in the container; CS2
  # itself also runs as root here so the security delta is zero.
  # PORT honored by src/electron/index.ts (PORT || 1349).
  # OPENHUD_AUTO_OVERLAY=1 is honored by our patch in
  # openhud/auto-overlay.patch — opens the fullscreen, transparent,
  # alwaysOnTop spectator HUD BrowserWindow on app-ready instead of
  # waiting for an admin's UI click. Without this only the admin panel
  # window exists and there's no HUD to capture.
  # --mute-audio: Chromium flag that silences all renderer audio.
  # OpenHud's HUD pages can include sound effects (round end, kill,
  # bomb plant); without muting, Electron writes those samples into
  # whatever Pulse considers the default sink — which is our cs2 null
  # sink — and they leak into the captured stream alongside (or in
  # place of) the real game audio. The HUD is purely visual for our
  # use case, so muting here is free.
  PORT="$OPENHUD_PORT" \
  OPENHUD_AUTO_OVERLAY=1 \
    spawn_logged openhud "$OPENHUD_BIN" --no-sandbox --disable-gpu-sandbox --mute-audio
  log "  openhud pid=$SPAWNED_PID"
}

# Poll the local HUD endpoint until it answers. Waits indefinitely —
# the only abort condition is the openhud process actually exiting
# (a real failure that retrying won't fix). The "timeout" arg is
# still accepted for callsite compatibility but treated as no-op.
wait_for_openhud_server() {
  log "waiting for OpenHud server on :${OPENHUD_PORT}"
  local i=0
  while :; do
    if openhud_server_up; then
      log "  openhud server up after ${i}s"
      return 0
    fi
    if ! openhud_running; then
      warn "openhud process exited early (see [openhud] log lines above)"
      return 1
    fi
    i=$(( i + 1 ))
    if [ $(( i % 30 )) -eq 0 ]; then
      log "  still waiting (${i}s)"
    fi
    sleep 1
  done
}

stop_openhud() {
  pkill -f "$OPENHUD_BIN" 2>/dev/null || true
}

# ---- window helpers ------------------------------------------------------
# OpenHud opens TWO BrowserWindows:
#   * the admin/control panel (titled "OpenHud", default 1024x768) — we
#     don't want this on screen at all, capture would pick it up.
#   * the HUD overlay (loads /api/hud, transparent + frameless) — this is
#     what we want raised on top of CS2.
#
# We tell them apart by title: the admin panel has a non-empty WM_NAME
# starting with "OpenHud"; the overlay window is borderless and typically
# has either an empty title or one matching the page <title>. If upstream
# changes title strings these matchers will need updating.

# Hide the admin panel by moving it offscreen + unmapping. xdotool's
# windowunmap alone is sometimes ignored by Electron windows that re-show
# themselves on focus; the offscreen move is a fallback.
#
# Picking the right window matters: Electron creates several utility
# windows with WM_NAME="openhud" (lowercase) — `xdotool search --name`
# is case-insensitive and would grab one of those. We match
# WM_CLASS=openhud (Electron's app id) AND WM_NAME EXACTLY "OpenHud"
# — the spectator HUD's name is "OpenHud Default HUD" or whatever the
# active HUD's index.html sets, only the admin keeps the bare title.
hide_openhud_admin_window() {
  local id name target=""
  for id in $(xdotool search --classname '^openhud' 2>/dev/null); do
    name=$(xdotool getwindowname "$id" 2>/dev/null || true)
    if [ "$name" = "OpenHud" ]; then
      target="$id"; break
    fi
  done
  if [ -z "$target" ]; then
    log "no OpenHud admin window to hide (yet)"
    return 0
  fi
  log "hiding OpenHud admin window: $target"
  xdotool windowminimize "$target"            2>/dev/null || true
  wmctrl -ir "$target" -b add,hidden          2>/dev/null || true
  xdotool windowunmap "$target"               2>/dev/null || true
  xdotool windowmove "$target" -3000 -3000    2>/dev/null || true
}

# Find the HUD overlay window. Heuristic: largest WM_CLASS=openhud
# window at least 1280x720. Size is the only reliable discriminator:
# the active HUD sets its own page <title> (e.g. "OpenHud Default HUD"),
# which can collide with the admin window's title prefix "OpenHud".
# The admin window defaults to 1200x700, so a 1280x720 floor cleanly
# separates admin from the fullscreen spectator HUD.
#
# Without the size floor, xdotool returns Electron's invisible utility
# windows (16x16, 200x200, 10x10) and we'd "position" one of those at
# 1920x1080, capturing a blank window instead of the real HUD.
find_openhud_overlay_window() {
  local min_w="${OPENHUD_MIN_W:-1280}"
  local min_h="${OPENHUD_MIN_H:-720}"
  local id w h area best=0 best_id=""
  for id in $(xdotool search --classname '^openhud' 2>/dev/null); do
    # xdotool getwindowgeometry --shell prints WIDTH=, HEIGHT=, X=, Y=
    # Unset before eval so a stale value from the prior iteration
    # doesn't leak in if the window vanishes mid-loop (eval of empty
    # string is a no-op and would silently keep last iteration's size).
    unset WIDTH HEIGHT X Y SCREEN
    eval "$(xdotool getwindowgeometry --shell "$id" 2>/dev/null)"
    w="${WIDTH:-0}"; h="${HEIGHT:-0}"
    [ "$w" -ge "$min_w" ] && [ "$h" -ge "$min_h" ] || continue
    area=$((w * h))
    if [ "$area" -gt "$best" ]; then
      best="$area"; best_id="$id"
    fi
  done
  [ -n "$best_id" ] && echo "$best_id"
}

# Move the overlay window to (0,0) at OPENHUD_OVERLAY_W x OPENHUD_OVERLAY_H
# and raise it above cs2 so ximagesrc captures CS2 + HUD composited.
#
# Polls for up to OPENHUD_OVERLAY_TIMEOUT (default 30s) for the overlay
# to exist. The auto-overlay patch opens the spectator HUD ~2s after
# Electron's app-ready, so calling this immediately after start_openhud
# can race ahead of the window — wait for it to actually appear. If
# openhud has died (process gone), respawn it and keep waiting.
#
# When the overlay never appears, dump openhud's process state + every
# openhud-class window we can see so the operator can tell whether the
# HUD window was destroyed (process alive but no big window) vs the
# whole Electron app crashed.
position_openhud_overlay() {
  local timeout="${OPENHUD_OVERLAY_TIMEOUT:-30}"
  local id="" i wid wname
  for i in $(seq 1 "$timeout"); do
    id=$(find_openhud_overlay_window)
    [ -n "$id" ] && break
    if ! openhud_running; then
      warn "openhud process died — restarting"
      stop_openhud; sleep 1
      start_openhud
      wait_for_openhud_server 30 || warn "respawned openhud not responding"
    fi
    sleep 1
  done
  if [ -z "$id" ]; then
    warn "no OpenHud overlay window after ${timeout}s — HUD won't be visible"
    log "  openhud pid: $(pgrep -f "$OPENHUD_BIN" | head -1 || echo NONE)"
    log "  openhud-class windows currently mapped:"
    while IFS= read -r wid; do
      [ -n "$wid" ] || continue
      wname=$(xdotool getwindowname "$wid" 2>/dev/null || true)
      unset WIDTH HEIGHT X Y SCREEN
      eval "$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null)"
      log "    $wid \"$wname\" ${WIDTH:-?}x${HEIGHT:-?}+${X:-?}+${Y:-?}"
    done < <(xdotool search --classname '^openhud' 2>/dev/null)
    return 1
  fi
  log "positioning OpenHud overlay window $id ($OPENHUD_OVERLAY_W x $OPENHUD_OVERLAY_H @ 0,0)"
  xdotool windowmove "$id" 0 0                                    2>/dev/null || true
  xdotool windowsize "$id" "$OPENHUD_OVERLAY_W" "$OPENHUD_OVERLAY_H" 2>/dev/null || true
  wmctrl -ir "$id" -b add,above                                   2>/dev/null || true
  xdotool windowraise "$id"                                       2>/dev/null || true
}

# ---- GSI cfg drop --------------------------------------------------------
# Write the gamestate_integration_openhud.cfg into CS2's cfg dir so cs2
# POSTs game state to OpenHud at engine start. We prefer the cfg from the
# OpenHud tarball (so it stays in lockstep with the server) but fall back
# to writing a minimal one ourselves if the tarball cfg isn't found.
write_openhud_gsi_cfg() {
  local cfg_dir="$CS2_DIR/game/csgo/cfg"
  mkdir -p "$cfg_dir"
  local dst="$cfg_dir/gamestate_integration_openhud.cfg"

  local src
  src=$(find /opt/openhud -name 'gamestate_integration_openhud.cfg' \
          -type f 2>/dev/null | head -1 || true)
  if [ -n "$src" ]; then
    log "writing GSI cfg from $src to $dst"
    cp -f "$src" "$dst"
  else
    log "writing fallback GSI cfg to $dst (tarball cfg not found)"
    cat >"$dst" <<EOF
"OpenHud Game State Integration"
{
  "uri" "http://${OPENHUD_HOST}:${OPENHUD_PORT}/api/gsi"
  "timeout" "5.0"
  "buffer" "0.0"
  "throttle" "0.1"
  "heartbeat" "10.0"
  "auth" { "token" "${OPENHUD_GSI_TOKEN}" }
  "data"
  {
    "provider"        "1"
    "map"             "1"
    "round"           "1"
    "player_id"       "1"
    "player_state"    "1"
    "player_weapons"  "1"
    "player_match_stats" "1"
    "allplayers_id"   "1"
    "allplayers_state" "1"
    "allplayers_match_stats" "1"
    "allplayers_weapons" "1"
    "allplayers_position" "1"
    "phase_countdowns" "1"
    "allgrenades"     "1"
    "bomb"            "1"
  }
}
EOF
  fi
}

# ---- spec keybinds -------------------------------------------------------
# CS2 spec actions that the spec-server (src/spec-server.mjs) drives are
# pre-bound to F-keys here so the server only ever has to send a single
# keystroke via xdotool — never open the dev console, never activate
# the cs2 window. Activating cs2 restacks it above the OpenHud overlay
# (and on this Openbox+picom setup, can outright destroy the overlay
# window), so avoiding activation is the difference between an HUD
# that survives and one the operator has to manually re-open every
# player switch.
#
# Static map (mirrored in spec-server.mjs — change both together):
#   F1 = spec_next        (/spec/click button=left)
#   F2 = spec_prev        (/spec/click button=right)
#   F3 = +jump            (/spec/jump — toggles lock-on/free-roam)
#   F4 = autodirector ON  (/spec/autodirector enabled=true)
#   F5 = autodirector OFF (/spec/autodirector enabled=false)
#   F6-F12 = per-player slots, written by write_spec_player_binds
#            from the seeded match metadata (up to 7 lineup players).
spec_static_binds_block() {
  cat <<'EOF'
// === spec-server keybinds (auto-generated; mirror in src/spec-server.mjs) ===
bind "F1" "spec_next"
bind "F2" "spec_prev"
bind "F3" "+jump"
bind "F4" "spec_autodirector 1; spec_mode 5"
bind "F5" "spec_autodirector 0"
EOF
}

# Demo-playback keybinds. Every interactive control the operator
# touches resolves to a key press here — no console flash, no
# typed-input fragility. Mirrored in src/spec-server.mjs's KEY_DEMO_*
# constants — change both together.
#
# CS2's demo system uses tick offsets for relative seeking. We assume
# 64-tick demos for the bind table (most pro/CS2 demos); ±15s = ±960
# ticks. If we ever support sub-tick or 128-tick demos this needs to
# parameterise — for now hardcoded.
#
#   Pause       = demo_togglepause   (/demo/toggle)
#   Home        = demo_gototick -960 (/demo/skip secs=-15)
#   End         = demo_gototick +960 (/demo/skip secs=+15)
#   Insert      = host_timescale 1   (/demo/speed rate=1)
#   PageDown    = host_timescale 0.25 (/demo/speed rate=0.25)
#   semicolon   = host_timescale 0.5 (/demo/speed rate=0.5)
#   apostrophe  = host_timescale 2   (/demo/speed rate=2)
#   PageUp      = host_timescale 4   (/demo/speed rate=4)
demo_static_binds_block() {
  cat <<'EOF'
// === demo-playback keybinds (auto-generated; mirror in src/spec-server.mjs) ===
// Every constant-arg console action lives here so the spec-server can
// fire it via XTest keystroke instead of typing into the dev console
// (which flashes briefly on the captured stream). Parameterized
// actions (demo_gototick <tick>) still need typed console.
bind "PAUSE" "demo_togglepause"
bind "HOME" "demo_gototick -960"
bind "END" "demo_gototick +960"
bind "INS" "host_timescale 1"
bind "SEMICOLON" "host_timescale 0.5"
bind "APOSTROPHE" "host_timescale 2"
bind "PGUP" "host_timescale 4"
bind "PGDN" "host_timescale 0.25"
bind "F11" "demoui"
bind "F12" "toggle spec_show_xray 0 1"
bind "F10" "playdemo /tmp/game-streamer/demo.dem"
EOF
}

# Append per-player `bind "F<n>" "spec_player_by_accountid <id>"` lines
# to the autoexec from the seeded match JSON, and write the
# accountid -> keysym map the spec-server reads at request time.
#
# Args:
#   $1 — path to the seeded match JSON (from seed_openhud_db)
#   $2 — autoexec.cfg to append to
#   $3 — JSON map output path (PLAYER_BINDINGS_PATH in spec-server.mjs)
#
# No-ops gracefully if the seed JSON is missing or empty — spec-server
# will then 404 /spec/player requests with a hint to reseed. Spec
# operators can still drive cycling via /spec/click and /spec/jump.
write_spec_player_binds() {
  local match_json="$1" autoexec="$2" map_out="$3"
  if [ ! -s "$match_json" ]; then
    log "no seeded match metadata at $match_json — skipping per-player binds"
    log "  /spec/player will 404 until run-live re-seeds; cycling (F1/F2) still works"
    : > "$map_out" 2>/dev/null || true
    return 0
  fi

  python3 - "$match_json" "$autoexec" "$map_out" <<'PY' 2>&1 | sed 's/^/    /'
import json, sys

match_json_path, autoexec_path, map_path = sys.argv[1], sys.argv[2], sys.argv[3]

# F6..F12 — 7 slots. Enough for 5v5 plus two subs in the lineup; if a
# match exceeds this and the operator wants direct-switch on slot 8+,
# extend the range here AND in spec-server.mjs's KEY_* constants.
KEYS = [f"F{n}" for n in range(6, 13)]

STEAMID64_BASE = 76561197960265728
def to_accountid(s):
    try:
        n = int(s)
    except (TypeError, ValueError):
        return None
    return n - STEAMID64_BASE if n > STEAMID64_BASE else n

with open(match_json_path) as f:
    raw = json.load(f)
match = raw.get('match', raw) if isinstance(raw, dict) else {}

binds = []
mapping = {}  # str(accountid) -> keysym
seen = set()
slot = 0
for lu in (match.get('lineups') or []):
    if slot >= len(KEYS):
        break
    for p in (lu.get('players') or lu.get('lineup_players') or []):
        if slot >= len(KEYS):
            break
        steam = (p.get('steam_id') or p.get('steamId') or
                 p.get('steamid64') or p.get('steamid'))
        aid = to_accountid(steam)
        if aid is None or aid in seen:
            continue
        seen.add(aid)
        key = KEYS[slot]
        binds.append(f'bind "{key}" "spec_player_by_accountid {aid}"')
        mapping[str(aid)] = key
        slot += 1

# Append to autoexec under a marker so a re-run is easy to spot in the
# file; cs2 takes the last bind for any given key, so re-runs just
# stack and the most recent map wins.
with open(autoexec_path, 'a') as f:
    f.write('\n// === per-player spec binds (auto-generated from match metadata) ===\n')
    f.write('\n'.join(binds))
    f.write('\n')

with open(map_path, 'w') as f:
    json.dump({
        'accountid_to_key': mapping,
        'keys': KEYS[:slot],
    }, f, indent=2)

print(f"wrote {slot} per-player binds (slots {KEYS[:slot]})")
PY
}

# ---- match-metadata seed -------------------------------------------------
# Best-effort seed of OpenHud's SQLite DB from the 5stack API. Two-step:
#   1. GET ${API_BASE}/matches/${MATCH_ID}        (5stack — exact path TBD)
#   2. POST translated objects to OpenHud REST    (/api/v2/matches etc.)
#
# Always non-fatal — if the API is unreachable or the schemas drift the
# HUD still runs (it'll just show fallback names from CS2 GSI provider
# data instead of curated player/team metadata).
seed_openhud_db() {
  local match_id="${1:?match id required}"
  if [ -z "$API_BASE" ]; then
    log "API_BASE not set — skipping OpenHud DB seed (HUD will fall back to GSI data)"
    return 0
  fi
  log "seeding OpenHud DB for match $match_id from $API_BASE"

  local hdr=()
  [ -n "$API_TOKEN" ] && hdr=(-H "Authorization: Bearer $API_TOKEN")

  local match_json
  # curl stderr streams through the script's stderr so failures show up
  # tagged in the k8s log without a temp file.
  if ! match_json=$(curl -fsS --max-time 10 "${hdr[@]}" \
        "${API_BASE%/}/matches/${match_id}" 2>&1 1>&3); then
    warn "match fetch failed (see [openhud-seed] log lines above)"
    return 0
  fi 3>&1

  printf '%s\n' "$match_json" >"$LOG_DIR/openhud-seed-match.json"
  log "  match metadata cached at $LOG_DIR/openhud-seed-match.json"

  # Translate + POST to OpenHud's REST. Exact upstream shape lives in
  # src/electron/api/v2/{teams,players,matches}/ in the OpenHud source —
  # we go through python3 (already in the image) for safe JSON handling
  # rather than jq (not installed) and shell out to curl per record.
  # Python writes to its own stderr → script stderr → k8s log.
  python3 - <<'PY' "$match_json" "http://${OPENHUD_HOST}:${OPENHUD_PORT}/api/v2"
import json, sys, urllib.request, urllib.error

raw, base = sys.argv[1], sys.argv[2]

def log(msg):
    sys.stderr.write(f"[openhud-seed] {msg}\n"); sys.stderr.flush()

def post(path, body):
    req = urllib.request.Request(
        base + path,
        data=json.dumps(body).encode(),
        headers={'Content-Type': 'application/json'},
        method='POST',
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            log(f"POST {path} -> {r.status}")
            return json.loads(r.read() or b'{}')
    except urllib.error.HTTPError as e:
        log(f"POST {path} -> HTTP {e.code}: {e.read().decode(errors='replace')}")
    except Exception as e:
        log(f"POST {path} -> {type(e).__name__}: {e}")
    return None

try:
    m = json.loads(raw)
except Exception as e:
    log(f"match json parse failed: {e}")
    sys.exit(0)

# Best-effort field probing — accept either a raw match record or a
# wrapper like {"match": {...}}. Adapt as the 5stack response shape
# settles.
match = m.get('match', m) if isinstance(m, dict) else {}
lineups = match.get('lineups') or []

team_ids = []
for lu in lineups:
    name = (lu.get('name') or lu.get('team_name')
            or (lu.get('team') or {}).get('name')
            or 'Team')
    short = (lu.get('short_name') or (lu.get('team') or {}).get('short_name')
             or name[:3].upper())
    resp = post('/teams', {'name': name, 'shortName': short, 'country': 'us'})
    tid = (resp or {}).get('id') or (resp or {}).get('_id')
    team_ids.append(tid)
    for p in lu.get('players') or lu.get('lineup_players') or []:
        steam = p.get('steam_id') or p.get('steamId') or p.get('steamid64') or ''
        first = p.get('name') or p.get('username') or 'Player'
        post('/players', {
            'firstName': first, 'lastName': '',
            'username': p.get('name') or first,
            'steamid': steam,
            'team': tid,
            'country': p.get('country') or 'us',
        })

if len(team_ids) >= 2:
    post('/matches', {
        'left':  {'id': team_ids[0], 'wins': 0},
        'right': {'id': team_ids[1], 'wins': 0},
        'matchType': 'Bo1',
        'current': True,
    })

PY
  return 0
}

# ---- status / debug ------------------------------------------------------
openhud_status() {
  log "openhud status:"
  if openhud_running; then
    log "  process: running (pid $(pgrep -f "$OPENHUD_BIN" | head -1))"
  else
    log "  process: NOT running"
  fi
  if openhud_server_up; then
    log "  server:  http://${OPENHUD_HOST}:${OPENHUD_PORT}/api/hud OK"
  else
    log "  server:  unreachable on :${OPENHUD_PORT}"
  fi
  if picom_running; then
    log "  picom:   running"
  else
    log "  picom:   NOT running (transparent overlay won't composite)"
  fi
  local admin overlay
  admin=$(xdotool search --name '^OpenHud' 2>/dev/null | head -1 || true)
  overlay=$(find_openhud_overlay_window || true)
  log "  admin window:   ${admin:-(none)}"
  log "  overlay window: ${overlay:-(none)}"
}
