#!/usr/bin/env bash
# Flow: render a single clip from a finished match's demo, upload mp4
# back to the api, exit. One-shot — no spec-server, no interactive
# control. Pod is reaped by k8s as soon as this script returns 0.
#
# Required env (injected by api/src/matches/clips/clips.service.ts):
#   MATCH_MAP_ID
#   DEMO_URL                presigned S3 GET for the .dem
#   CLIP_RENDER_JOB_ID      uuid of the clip_render_jobs row
#   CLIP_RENDER_TOKEN       session token (paired with JOB_ID for x-origin-auth)
#   CLIP_SPEC               full ClipSpec json (segments[], output{}, etc)
#   CLIP_OUTPUT_DIMS        '1280x720' | '1920x1080'
#   CLIP_OUTPUT_FPS         '30' | '60'
#   STATUS_API_BASE         api root (e.g. https://api.5stack.gg)
#   DEMO_TICK_RATE          (optional) tick rate from parser — for tick→sec math
#
# v1 spec: SINGLE segment only. Multi-segment + overlays + music are
# phase-2 — see /Users/luke/.claude/plans/on-our-demo-recorded-proud-bentley.md
# Multi-segment will land here as: render each segment to its own mp4
# and ffmpeg-concat afterwards before upload.
#
# Status flow: queued (set by api on insert) → rendering → uploading → done.
# Pod posts status to /clip-renders/:id/status; the web subscribes to
# the row and shows the determinate progress bar.

set -uo pipefail
SCRIPT_TAG=render-clip

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
# shellcheck disable=SC1091
. "$LIB_DIR/clip-capture.sh"

load_env
require_env MATCH_MAP_ID DEMO_URL CLIP_RENDER_JOB_ID CLIP_RENDER_TOKEN CLIP_SPEC

# status-reporter override: clip-render uses /clip-renders/:id/status
# instead of /demo-sessions/:id/status. status-reporter.sh consumes
# STATUS_REPORT_URL + STATUS_AUTH_TOKEN if set; otherwise it falls
# through to the demo-session promotion or the live-match default.
: "${STATUS_API_BASE:=http://api:5585}"
export STATUS_API_BASE
export STATUS_REPORT_URL="${STATUS_API_BASE}/clip-renders/${CLIP_RENDER_JOB_ID}/status"
export STATUS_AUTH_TOKEN="${CLIP_RENDER_JOB_ID}:${CLIP_RENDER_TOKEN}"
start_status_reporter

: "${DEMO_FILE:=/tmp/game-streamer/demo.dem}"
: "${CLIP_OUTPUT_DIMS:=1920x1080}"
: "${CLIP_OUTPUT_FPS:=60}"
: "${DEMO_TICK_RATE:=64}"
: "${CS2_LAUNCH_TIMEOUT:=300}"
: "${CS2_WINDOW_TIMEOUT:=300}"

CLIP_OUT_DIR="${CLIP_OUT_DIR:-/mnt/game-streamer/clips}"
mkdir -p "$CLIP_OUT_DIR" "$(dirname "$DEMO_FILE")"
CLIP_OUT_FILE="${CLIP_OUT_DIR}/${CLIP_RENDER_JOB_ID}.mp4"

# Parse the spec. We only consume segments[0] in v1; the api validates
# segments.length >= 1 + length cap so we trust it here.
START_TICK=$(printf '%s' "$CLIP_SPEC" | jq -r '.segments[0].start_tick')
END_TICK=$(printf '%s' "$CLIP_SPEC" | jq -r '.segments[0].end_tick')
[ "$START_TICK" = "null" ] || [ "$END_TICK" = "null" ] && \
  die "spec missing segments[0].start_tick or end_tick"
[ "$END_TICK" -le "$START_TICK" ] && \
  die "end_tick ($END_TICK) must be > start_tick ($START_TICK)"

DURATION_TICKS=$((END_TICK - START_TICK))
DURATION_SEC=$(awk -v t="$DURATION_TICKS" -v r="$DEMO_TICK_RATE" \
  'BEGIN{printf "%.3f", t/r}')

OUT_W=$(printf '%s' "$CLIP_OUTPUT_DIMS" | cut -dx -f1)
OUT_H=$(printf '%s' "$CLIP_OUTPUT_DIMS" | cut -dx -f2)

log "spec: ${DURATION_TICKS} ticks (${DURATION_SEC}s) at ${CLIP_OUTPUT_DIMS}@${CLIP_OUTPUT_FPS}fps"
log "out:  $CLIP_OUT_FILE"

report_status status=rendering progress=0.05

# ---------------------------------------------------------------------------
say "1. preflight"
steam_pipe_up || die "Steam isn't running. setup-steam should have run first."
xorg_running || die "Xorg isn't up. setup-steam should have run first."

restore_real_steamclient

say "2. wait for demo download"
# The dispatcher (game-streamer.sh `render-clip`) kicks off the demo
# download in parallel with setup-steam, same as the demo flow. By the
# time we get here it's almost always already on disk.
if [ ! -f "$DEMO_FILE" ] && [ ! -f "${DEMO_FILE}.failed" ] \
   && [ -f /tmp/game-streamer/demo-download.pid ]; then
  log "  waiting on parallel download"
  for i in $(seq 1 "${DEMO_DOWNLOAD_TIMEOUT:-300}"); do
    [ -f "$DEMO_FILE" ] || [ -f "${DEMO_FILE}.failed" ] && break
    [ $((i % 5)) -eq 0 ] && log "  ${i}s waiting..."
    sleep 1
  done
fi
[ -f "${DEMO_FILE}.failed" ] && die "demo download failed"
[ -f "$DEMO_FILE" ] || die "demo file never appeared at $DEMO_FILE"

# ---------------------------------------------------------------------------
say "3. write CS2 autoexec (clip mode)"
CS2_CFG_DIR="$CS2_DIR/game/csgo/cfg"
mkdir -p "$CS2_CFG_DIR"

# HUD hiding for clean clip output. Tighter than the demo-watch flow
# because clips don't need a scrubber/overlay — purely the cs2
# viewport. The autoexec runs at engine init so cvars take before the
# demo loads.
cat > "$CS2_CFG_DIR/autoexec.cfg" <<EOF
// auto-generated by src/flows/render-clip.sh — clip render mode
con_enable 1
snd_mute_losefocus 0
engine_no_focus_sleep 0
volume 1.0
cl_drawhud 0
r_drawviewmodel 0
cl_show_observer_crosshair 0
spec_show_xray 0
demoui 0
demo_pause
EOF

# ---------------------------------------------------------------------------
say "4. launch CS2"
report_status status=rendering progress=0.10

export PULSE_SINK="${PULSE_SINK_NAME:-cs2}"
: "${PULSE_SERVER:=tcp:${PULSE_TCP_HOST:-127.0.0.1}:${PULSE_TCP_PORT:-4713}}"
export PULSE_SERVER

CS2_BIN="$CS2_DIR/game/bin/linuxsteamrt64/cs2"
[ -x "$CS2_BIN" ] || die "CS2 binary missing at $CS2_BIN"
cd "$(dirname "$CS2_BIN")"

CS2_LAUNCH_ARGS=(
  -windowed -noborder -width "$OUT_W" -height "$OUT_H" -novid -nojoy -console
  -insecure
  +exec autoexec
  +playdemo "$DEMO_FILE"
)
log "  applaunch 730 ${CS2_LAUNCH_ARGS[*]}"
spawn_logged cs2-launch "$STEAM_HOME/ubuntu12_32/steam" -applaunch 730 "${CS2_LAUNCH_ARGS[@]}"

# Wait for cs2 window — same pattern as run-demo.sh.
CS2_PID=""
for i in $(seq 1 "$CS2_LAUNCH_TIMEOUT"); do
  CS2_PID=$(pgrep -f '/linuxsteamrt64/cs2' | head -1)
  [ -n "$CS2_PID" ] && break
  [ $((i % 15)) -eq 0 ] && log "  ${i}s elapsed waiting on cs2..."
  sleep 1
done
[ -n "$CS2_PID" ] || die "CS2 never launched in ${CS2_LAUNCH_TIMEOUT}s"

WIN=""
for i in $(seq 1 "$CS2_WINDOW_TIMEOUT"); do
  WIN=$(xwininfo -display "$DISPLAY" -root -tree 2>/dev/null \
    | awk '/"Counter-Strike 2"/{print $1; exit}')
  [ -n "$WIN" ] && break
  if ! kill -0 "$CS2_PID" 2>/dev/null; then
    die "CS2 exited before opening window"
  fi
  sleep 1
done
[ -n "$WIN" ] || die "no CS2 window after ${CS2_WINDOW_TIMEOUT}s"
log "  cs2 window up after ${i}s"
minimize_steam_windows

# ---------------------------------------------------------------------------
say "5. seek to start_tick"
report_status status=rendering progress=0.20
# CS2's demo command surface: demo_gototick <tick> seeks to absolute
# tick (paused, frame-stepped to that exact frame). demo_resume
# starts wallclock playback. Send via the cs2 console — same xdotool
# path the spec-server uses for live demo control.
cs2_console_command "demo_gototick $START_TICK"
sleep 2
# Small lead-in so the encoder has clean keyframe before the action
# we care about. The api already adds 5s of lead in some kill-jump
# UIs; for arbitrary in-points we just give the encoder a moment to
# stabilise after the seek.

# ---------------------------------------------------------------------------
say "6. start clip capture"
start_clip_capture "$CLIP_OUT_FILE" "$CLIP_OUTPUT_FPS" 8000 1 \
  || die "clip capture failed to start"

cs2_console_command "demo_resume"
report_status status=rendering progress=0.30

# Wallclock duration of the segment at 1.0x replay rate. We don't
# bother with demo_timescale > 1 here — h264 encode cost on the GPU
# is already real-time, and high-rate replays risk frame drops on
# the GPU encoder ringbuffer that aren't worth the wallclock saving.
log "  capturing for ${DURATION_SEC}s (cs2 demo plays at 1.0x)"

# Periodic progress reports while capturing — each tick is ~5% of
# remaining range, capped at 0.95 so we always have headroom for the
# upload phase.
START_MS=$(date +%s%3N)
END_MS=$(awk -v s="$START_MS" -v d="$DURATION_SEC" 'BEGIN{printf "%d", s + d*1000}')
LAST_REPORT=0
while :; do
  NOW_MS=$(date +%s%3N)
  [ "$NOW_MS" -ge "$END_MS" ] && break
  if [ $((NOW_MS - LAST_REPORT)) -ge 2000 ]; then
    FRAC=$(awk -v n="$NOW_MS" -v s="$START_MS" -v e="$END_MS" \
      'BEGIN{printf "%.3f", 0.30 + 0.60 * (n - s) / (e - s)}')
    report_status status=rendering "progress=$FRAC"
    LAST_REPORT=$NOW_MS
  fi
  if ! kill -0 "${CLIP_CAPTURE_PID:-0}" 2>/dev/null; then
    die "clip capture died mid-render"
  fi
  if ! kill -0 "$CS2_PID" 2>/dev/null; then
    die "cs2 died mid-render"
  fi
  sleep 1
done

say "7. stop capture"
stop_clip_capture
report_status status=rendering progress=0.92

[ -s "$CLIP_OUT_FILE" ] || die "clip output is empty: $CLIP_OUT_FILE"
CLIP_BYTES=$(stat -c '%s' "$CLIP_OUT_FILE" 2>/dev/null || stat -f '%z' "$CLIP_OUT_FILE")
log "  rendered $CLIP_OUT_FILE ($CLIP_BYTES bytes)"

# ffprobe gives us the actual mp4 duration (gst's qtmux finalises the
# wallclock duration into moov, which can drift slightly from our
# tick math if cs2 dropped frames or paused unexpectedly). Sent up to
# the api so the library card shows the true clip length.
DURATION_MS=$(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 "$CLIP_OUT_FILE" 2>/dev/null \
  | awk '{printf "%d", $1 * 1000}')
[ -z "$DURATION_MS" ] && DURATION_MS=$(awk -v d="$DURATION_SEC" \
  'BEGIN{printf "%d", d * 1000}')
log "  clip duration: ${DURATION_MS}ms"

# ---------------------------------------------------------------------------
say "8. upload"
report_status status=uploading progress=0.95

UPLOAD_URL="${STATUS_API_BASE:?STATUS_API_BASE not set}/clip-renders/${CLIP_RENDER_JOB_ID}/upload"
log "  POST $UPLOAD_URL ($CLIP_BYTES bytes)"

if ! curl --fail --silent --show-error \
       --max-time 1800 \
       --header "x-origin-auth: ${CLIP_RENDER_JOB_ID}:${CLIP_RENDER_TOKEN}" \
       --header "content-type: application/octet-stream" \
       --header "x-clip-duration-ms: ${DURATION_MS}" \
       --data-binary "@${CLIP_OUT_FILE}" \
       --output /tmp/clip-upload-response.json \
       "$UPLOAD_URL"; then
  die "clip upload failed (see http response in /tmp/clip-upload-response.json)"
fi

# api returns { clipId, s3Url }; we don't need the body for anything,
# the row state already reflects success.
report_status status=done progress=1.0
log "  uploaded ok"

# Cleanup local file — the K8s emptyDir / hostPath would clean itself
# eventually but explicit rm makes the pod log easier to read.
rm -f "$CLIP_OUT_FILE"

# Best-effort cs2 shutdown so the pod terminates cleanly. K8s will
# kill the container regardless once the entry script exits, but a
# graceful cs2 quit avoids a confusing "exited unexpectedly" line in
# the cs2 watchdog log.
pkill -TERM -f '/linuxsteamrt64/cs2' 2>/dev/null || true
sleep 1
pkill -9 -f '/linuxsteamrt64/cs2' 2>/dev/null || true

say "done — clip rendered and uploaded for job $CLIP_RENDER_JOB_ID"
exit 0
