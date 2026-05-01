#!/usr/bin/env bash
# Flow 2 (demo variant) — launch CS2 against a downloaded .dem file and
# start the match-capture stream. Mirrors run-live.sh; the only differences
# are: (a) pull the demo from DEMO_URL, (b) `+playdemo` instead of
# `+connect`/`+playcast`, (c) demo-control keybinds in autoexec.
#
# Prerequisite: Steam must already be logged in (run flow 1 first).
#
# Required env:
#   MATCH_ID
#   MATCH_MAP_ID    — for telemetry / job naming; cosmetic in this script
#   DEMO_URL        — pre-signed S3 GET for the .dem (api/src/demos issues this)
#
# Optional env:
#   ROUND_TICKS     — JSON [{round,start_tick,end_tick},...] from the
#                     demo-parser. Not consumed here directly — passed
#                     through env so spec-server can read it for
#                     /demo/round routing without an extra round-trip.
#   DEMO_FORMAT     — "auto" (default) | "dem" — leave at auto.

set -uo pipefail
SCRIPT_TAG=run-demo

# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/xorg.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/stream.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/audio.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/steam.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/openhud.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/status-reporter.sh"

load_env
require_env MATCH_ID DEMO_URL

# status-reporter auto-derives its override from DEMO_SESSION_ID /
# DEMO_SESSION_TOKEN (set as pod env by the api), so just call start.
# setup-steam.sh's earlier start_status_reporter picks up the same
# override — no race, no special-casing per flow.
start_status_reporter

: "${FPS:=30}"
: "${VIDEO_KBPS:=6000}"
: "${CS2_LAUNCH_TIMEOUT:=300}"
: "${CS2_WINDOW_TIMEOUT:=300}"
: "${DEBUG_STREAM_ID:=debug}"
: "${DEMO_DOWNLOAD_TIMEOUT:=300}"
: "${DEMO_FILE:=/tmp/game-streamer/demo.dem}"

mkdir -p "$(dirname "$DEMO_FILE")"

if [ "${DEBUG_CAPTURE:-0}" = "1" ]; then
  say "0. debug capture stream"
  start_xorg
  start_capture "$DEBUG_STREAM_ID" 30 4000 true 0
  log "watch debug: https://hls.5stack.gg/${DEBUG_STREAM_ID}/"
fi

# ---------------------------------------------------------------------------
say "1. preflight"
steam_pipe_up || die "Steam isn't running. Run flow 1 (setup-steam) first."
log "  steam pipe up (pid $(cat "$HOME/.steam/steam.pid"))"
xorg_running || die "Xorg isn't up. Run flow 1 (setup-steam) first."
log "  xorg up on $DISPLAY"

restore_real_steamclient

# ---------------------------------------------------------------------------
say "2. clean up stale CS2 / capture for this match"
pkill -9 -f '/linuxsteamrt64/cs2' 2>/dev/null || true
stop_capture "$MATCH_ID"
sleep 1
rm -f /tmp/source_engine_*.lock
rm -f "$CS2_DIR/game/csgo/steam_appid.txt" \
      "$CS2_DIR/game/bin/linuxsteamrt64/steam_appid.txt" 2>/dev/null || true

# ---------------------------------------------------------------------------
say "2b. download demo"
report_status status=downloading_demo \
  "stream_url=${MEDIAMTX_SRT_BASE}?streamid=publish:${MATCH_ID}"
# game-streamer.sh's `demo` flow kicks the download off in parallel
# with setup-steam. By the time we get here it's usually already on
# disk; if not, we wait on the marker files. As a defensive backstop,
# if neither marker shows up (e.g. someone invoked run-demo.sh
# directly without the parallel kickoff), we download inline.
if [ ! -f "$DEMO_FILE" ] && [ ! -f "${DEMO_FILE}.failed" ] \
   && [ -f /tmp/game-streamer/demo-download.pid ]; then
  log "  waiting on parallel download (started during setup-steam)"
  for i in $(seq 1 "$DEMO_DOWNLOAD_TIMEOUT"); do
    [ -f "$DEMO_FILE" ] || [ -f "${DEMO_FILE}.failed" ] && break
    [ $((i % 5)) -eq 0 ] && log "  ${i}s waiting..."
    sleep 1
  done
fi

if [ -f "${DEMO_FILE}.failed" ]; then
  die "demo download failed from $DEMO_URL (see [demo-download] log lines above)"
fi

if [ ! -f "$DEMO_FILE" ]; then
  log "  no parallel download in progress — fetching inline"
  if ! curl --fail --silent --show-error --location \
            --retry 5 --retry-delay 2 --retry-all-errors \
            --max-time "$DEMO_DOWNLOAD_TIMEOUT" \
            --output "$DEMO_FILE" \
            "$DEMO_URL"; then
    die "demo download failed from $DEMO_URL (after retries)"
  fi
fi

DEMO_BYTES=$(stat -c '%s' "$DEMO_FILE" 2>/dev/null || stat -f '%z' "$DEMO_FILE")
log "  saved $DEMO_FILE (${DEMO_BYTES} bytes)"

# ---------------------------------------------------------------------------
say "3. write CS2 autoexec"
CS2_CFG_DIR="$CS2_DIR/game/csgo/cfg"
mkdir -p "$CS2_CFG_DIR"

read -r -d '' HIDE_UI_CMDS <<'EOF' || true
snd_mute_losefocus 0
engine_no_focus_sleep 0
volume 1.0
// Demo-mode HUD hiding. None of these are sv_cheats-gated for demo
// playback (no server), so they stick at engine init and we don't
// have to chase the demoui panel with a post-load F11 toggle. If
// the operator wants any of these back on the manual demoui button
// in the web UI fires F11 to toggle the panel.
demoui 0
cl_drawhud 0
r_drawviewmodel 0
cl_show_observer_crosshair 0
spec_show_xray 0
EOF

SPEC_BINDS_BLOCK="$(spec_static_binds_block)"
DEMO_BINDS_BLOCK="$(demo_static_binds_block)"

OBSERVER_SRC="$SRC_DIR/../resources/observer.cfg"
EXEC_OBSERVER=""
if [ -x "${OPENHUD_BIN:-/opt/openhud/openhud}" ] && [ -f "$OBSERVER_SRC" ]; then
  cp -f "$OBSERVER_SRC" "$CS2_CFG_DIR/observer.cfg"
  log "  wrote $CS2_CFG_DIR/observer.cfg (from $OBSERVER_SRC)"
  EXEC_OBSERVER="exec observer.cfg"
fi

# No `playdemo` in the cfg — `+playdemo` is on the launch line below.
cat > "$CS2_CFG_DIR/autoexec.cfg" <<EOF
// auto-generated by src/flows/run-demo.sh — demo playback mode
con_enable 1
$HIDE_UI_CMDS
$EXEC_OBSERVER
$SPEC_BINDS_BLOCK
$DEMO_BINDS_BLOCK
EOF

# Keep OpenHud running for visual parity with live streams. GSI fires
# during demo playback too (CS2 emits gamestate from the recorded
# match), so the lineup HUD will populate the same way.
#
# setup-steam.sh runs the seed in parallel with the Steam UI wait —
# wait briefly for the marker, fall back to inline if it didn't run.
say "3b. OpenHud GSI cfg + DB seed"
PREP_MARKER="$LOG_DIR/match-cfgs-prepared"
PREP_FAILED="$LOG_DIR/match-cfgs-failed"
PREP_SKIPPED="$LOG_DIR/match-cfgs-skipped"
if [ -f "$PREP_MARKER" ]; then
  log "  parallel cfg-prep already finished — reusing seeded match metadata"
elif [ -f "$PREP_SKIPPED" ]; then
  log "  parallel cfg-prep was skipped — running inline"
  write_openhud_gsi_cfg
  seed_openhud_db "$MATCH_ID"
else
  if [ ! -f "$PREP_FAILED" ]; then
    log "  waiting up to 5s for parallel cfg-prep marker"
    for _ in $(seq 1 10); do
      [ -f "$PREP_MARKER" ] || [ -f "$PREP_FAILED" ] && break
      sleep 0.5
    done
  fi
  if [ -f "$PREP_MARKER" ]; then
    log "  parallel cfg-prep finished — reusing seeded match metadata"
  else
    [ -f "$PREP_FAILED" ] && warn "  parallel cfg-prep failed — retrying inline"
    write_openhud_gsi_cfg
    seed_openhud_db "$MATCH_ID"
  fi
fi

say "3c. CS2 spec per-player binds"
write_spec_player_binds \
  "$LOG_DIR/openhud-seed-match.json" \
  "$CS2_CFG_DIR/autoexec.cfg" \
  "$LOG_DIR/spec-bindings.json"

cp "$CS2_CFG_DIR/autoexec.cfg" "$CS2_CFG_DIR/live_autoexec.cfg"
log "  wrote $CS2_CFG_DIR/autoexec.cfg + live_autoexec.cfg"

# Drop ROUND_TICKS into a sidecar file the spec-server reads at request
# time, so /demo/round can resolve "round 5" -> tick without a round-trip
# back to the api. Permissive — empty if the parser hasn't run yet.
ROUND_TICKS_PATH="${LOG_DIR}/demo-round-ticks.json"
if [ -n "${ROUND_TICKS:-}" ]; then
  printf '%s\n' "$ROUND_TICKS" > "$ROUND_TICKS_PATH"
  log "  wrote round-ticks ($(wc -c < "$ROUND_TICKS_PATH") bytes) to $ROUND_TICKS_PATH"
else
  : > "$ROUND_TICKS_PATH"
  log "  no ROUND_TICKS provided — /demo/round will 404 until parser populates"
fi

for base in libpangoft2-1.0 libpango-1.0; do
  if [ ! -e "$CS2_DIR/game/bin/linuxsteamrt64/${base}.so" ] \
     && [ -e "$CS2_DIR/game/bin/linuxsteamrt64/${base}.so.0" ]; then
    ln -sf "${base}.so.0" "$CS2_DIR/game/bin/linuxsteamrt64/${base}.so" || true
  fi
done

CS2_BIN="$CS2_DIR/game/bin/linuxsteamrt64/cs2"
[ -x "$CS2_BIN" ] || die "CS2 binary missing at $CS2_BIN"
cd "$(dirname "$CS2_BIN")"

# ---------------------------------------------------------------------------
# Wait for the workshop map prefetch (started in parallel with
# setup-steam by game-streamer.sh's `demo` flow). For stock-map demos
# this block is a no-op — WORKSHOP_ID is empty.
#
# CS2 would otherwise stall on a Subscribe? prompt the moment the
# +playdemo arg touches a workshop map.
if [ -n "${WORKSHOP_ID:-}" ]; then
  say "3d. workshop map ${WORKSHOP_ID}"
  report_status status=downloading_workshop_map "workshop_id=${WORKSHOP_ID}"
  WORKSHOP_TARGET="${STEAM_LIBRARY}/steamapps/workshop/content/730/${WORKSHOP_ID}"
  WORKSHOP_FAILED="/tmp/game-streamer/workshop-${WORKSHOP_ID}.failed"
  WORKSHOP_TIMEOUT="${WORKSHOP_DOWNLOAD_TIMEOUT:-180}"

  if compgen -G "$WORKSHOP_TARGET/*.vpk" >/dev/null 2>&1; then
    log "  already on disk (parallel download finished during setup)"
  elif [ -f /tmp/game-streamer/workshop-download.pid ]; then
    log "  waiting on parallel workshop download (started during setup-steam)"
    for i in $(seq 1 "$WORKSHOP_TIMEOUT"); do
      compgen -G "$WORKSHOP_TARGET/*.vpk" >/dev/null 2>&1 && break
      [ -f "$WORKSHOP_FAILED" ] && break
      [ $((i % 5)) -eq 0 ] && log "  ${i}s waiting..."
      sleep 1
    done
  fi

  if [ -f "$WORKSHOP_FAILED" ] \
     || ! compgen -G "$WORKSHOP_TARGET/*.vpk" >/dev/null 2>&1; then
    log "  parallel download didn't deliver — falling back to inline download"
    download_workshop_map "$WORKSHOP_ID" \
      || warn "workshop map download failed — CS2 may stall on Subscribe prompt"
  else
    log "  workshop map ready"
  fi
fi

# ---------------------------------------------------------------------------
say "4. launch CS2 (demo mode)"
report_status status=launching_cs2
# Use Steam's +applaunch handoff (the proven path used by live
# streaming). Earlier we tried direct-exec for demos to skip the
# Steam UI wait; that combo (userdata-wait + direct-exec) launched
# cs2 against a half-bootstrapped Steam and the demo never loaded.
# Sequential: Steam pipe up → Steam UI rendered → applaunch cs2.
export PULSE_SINK="${PULSE_SINK_NAME:-cs2}"
: "${PULSE_SERVER:=tcp:${PULSE_TCP_HOST:-127.0.0.1}:${PULSE_TCP_PORT:-4713}}"
export PULSE_SERVER
log "  PULSE_SINK=$PULSE_SINK PULSE_SERVER=$PULSE_SERVER"

do_applaunch() {
  # +playdemo on the launch line: cs2 starts loading the demo during
  # engine init before its window even appears, so the stream never
  # shows the cs2 main menu. The console-typed fallback path is
  # racy (focus/timing) and was failing intermittently — going back
  # to the launch-arg form which has always been reliable here.
  local cs2_args=(
    -windowed -noborder -width 1920 -height 1080 -novid -nojoy -console
    -insecure
    +exec live_autoexec
    +playdemo "$DEMO_FILE")

  if [ "${LAUNCH_CS2_DIRECT:-0}" = "1" ]; then
    log "  exec (DIRECT): $CS2_BIN ${cs2_args[*]}"
    spawn_logged cs2-launch "$CS2_BIN" "${cs2_args[@]}"
    log "  cs2 direct launch (pid=$SPAWNED_PID)"
  else
    local cmd=("$STEAM_HOME/ubuntu12_32/steam" -applaunch 730 "${cs2_args[@]}")
    log "  exec: ${cmd[*]}"
    spawn_logged cs2-launch "${cmd[@]}"
    log "  applaunch sent (launcher pid=$SPAWNED_PID)"
  fi
}
do_applaunch
RELAUNCH_DONE=0

CS2_PID=""
for i in $(seq 1 "$CS2_LAUNCH_TIMEOUT"); do
  CS2_PID=$(pgrep -f '/linuxsteamrt64/cs2' | head -1)
  [ -n "$CS2_PID" ] && break

  if [ "$i" -ge 3 ] && [ "$i" -le 90 ] && [ $(( i % 5 )) -eq 0 ]; then
    poke_steam_dialog
  fi

  [ $(( i % 15 )) -eq 0 ] && log "  ${i}s elapsed waiting on cs2..."

  if [ "$i" = 30 ] && [ "$RELAUNCH_DONE" = 0 ]; then
    log "  30s without cs2 — re-issuing -applaunch (one-shot fallback)"
    do_applaunch
    RELAUNCH_DONE=1
  fi
  sleep 1
done
[ -n "$CS2_PID" ] || {
  log "--- $STEAM_LIBRARY/steam/logs/console-linux.txt (last 20) ---"
  tail -20 "$STEAM_LIBRARY/steam/logs/console-linux.txt" 2>/dev/null || true
  die "Steam never spawned cs2 in ${CS2_LAUNCH_TIMEOUT}s"
}
log "  cs2 pid=$CS2_PID"

minimize_steam_windows

# ---------------------------------------------------------------------------
say "5. wait for CS2 window"
report_status status=connecting_to_game
WIN=""
for i in $(seq 1 "$CS2_WINDOW_TIMEOUT"); do
  WIN=$(xwininfo -display "$DISPLAY" -root -tree 2>/dev/null \
    | awk '/"Counter-Strike 2"/{print $1; exit}')
  [ -n "$WIN" ] && { log "  window after ${i}s: $WIN"; break; }
  if ! kill -0 "$CS2_PID" 2>/dev/null; then
    log "--- cs2 console-linux.txt (last 60) ---"
    tail -60 "$STEAM_LIBRARY/steam/logs/console-linux.txt" 2>/dev/null
    die "cs2 EXITED early."
  fi
  [ $(( i % 15 )) -eq 0 ] && log "  still waiting for cs2 window (${i}s, pid=$CS2_PID alive)"
  sleep 1
done
[ -n "$WIN" ] || {
  log "--- cs2 console-linux.txt (last 60) ---"
  tail -60 "$STEAM_LIBRARY/steam/logs/console-linux.txt" 2>/dev/null
  die "no CS2 window after ${CS2_WINDOW_TIMEOUT}s"
}

say "5b. raise OpenHud overlay above cs2"
# Overlay raise is the only step gating the capture — without it,
# the HUD won't be on top when ximagesrc starts publishing. ~1s.
if openhud_running; then
  log "  triggering /api/overlay/start so HUD reloads with fresh game state"
  if curl -fsS -m 5 -X POST -o /dev/null \
       "http://${OPENHUD_HOST:-127.0.0.1}:${OPENHUD_PORT:-1349}/api/overlay/start"; then
    log "    overlay start ok"
    sleep 1
  else
    warn "    overlay start request failed — falling back to repositioning existing window"
  fi
  position_openhud_overlay || warn "overlay positioning failed — HUD may not be visible in stream"
else
  log "OpenHud not running — skipping overlay positioning"
fi

# Start streaming AS SOON AS cs2 has its window + the OpenHud overlay
# is on top. Previously we waited for the demo-load + demo-playing
# log signals before starting the capture, which added ~60–90s of
# the demo silently advancing while the operator watched a "booting"
# UI. The .dem starts playing immediately on cs2 window-up, so any
# delay between then and status=live is wasted demo time the user
# can never get back.
#
# The demoui-hide + idempotent playdemo fallback now run in the
# background — they don't gate going-live anymore. Worst case the
# operator sees the cs2 demoui panel for a few extra seconds while
# the stream catches up; that beats missing the first 60s of action.
CS2_LOG_TAIL="${CS2_LOG_TAIL:-$STEAM_LIBRARY/steam/logs/console-linux.txt}"

say "5c. start match capture stream"
start_capture "$MATCH_ID" "$FPS" "$VIDEO_KBPS" false 1 \
  || die "capture failed to publish — see [gst-${MATCH_ID:0:8}] log lines above"

report_status status=live \
  "stream_url=${MEDIAMTX_SRT_BASE}?streamid=publish:${MATCH_ID}" \
  "playback_mode=demo"

# No background demoui-hide watcher needed — `demoui 0` in HIDE_UI_CMDS
# stops cs2 from auto-opening the panel on playdemo. The manual
# /demo/demoui endpoint (web "Toggle CS2 demo HUD" button) is still
# wired for cases where the operator wants the panel visible.

# Liveness watchdog: if cs2 dies any time after we kicked playdemo,
# surface it loudly. Without this, a silent crash leaves the pod in
# a "status=live but no frames" state until the operator notices.
(
  while kill -0 "$CS2_PID" 2>/dev/null; do
    sleep 5
  done
  warn "cs2 (pid=$CS2_PID) exited — see $CS2_LOG_TAIL"
  if command -v report_status >/dev/null 2>&1; then
    report_status status=errored "error=cs2 process exited unexpectedly"
  fi
) &
log "  cs2-alive watchdog started (pid $!)"

say "done"
log "watch:    https://hls.5stack.gg/${MATCH_ID}/"
log "demo:     $DEMO_FILE"
log "stop:     src/game-streamer.sh stop-live"

say "holding job alive — waiting for external stop"
while :; do
  sleep 3600 &
  wait $!
done
