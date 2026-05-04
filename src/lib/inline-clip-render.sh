#!/usr/bin/env bash
set -uo pipefail
SCRIPT_TAG=inline-clip

# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/clip-capture.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/stream.sh"

require_env CLIP_RENDER_JOB_ID CLIP_RENDER_TOKEN STATUS_API_BASE \
            CLIP_START_TICK CLIP_END_TICK SPEC_SERVER_URL

CLIP_RENDER_SPEED="${CLIP_RENDER_SPEED:-1}"

LOG_PREFIX="[clip ${CLIP_RENDER_JOB_ID:0:8}]"
say() { printf '%s %s\n' "$LOG_PREFIX" "$*" >&2; }

api_status() {
  local body
  body=$(python3 - "$@" <<'PY'
import json, sys
out = {}
for arg in sys.argv[1:]:
    if "=" not in arg:
        continue
    k, v = arg.split("=", 1)
    if k == "progress":
        try:
            out[k] = float(v)
        except ValueError:
            continue
    else:
        out[k] = v
print(json.dumps(out))
PY
)
  curl --fail --silent --show-error --max-time 10 \
       --header "x-origin-auth: ${CLIP_RENDER_JOB_ID}:${CLIP_RENDER_TOKEN}" \
       --header "content-type: application/json" \
       --data "$body" \
       --output /dev/null \
       "${STATUS_API_BASE}/clip-renders/${CLIP_RENDER_JOB_ID}/status" \
    || say "WARN status post failed: $*"
}

spec_get_state() {
  curl --fail --silent --show-error --max-time 5 \
       "${SPEC_SERVER_URL}/demo/state"
}

spec_post() {
  local path="$1"; shift
  local body="${1:-\{\}}"
  local http_code
  http_code=$(printf '%s' "$body" \
    | curl --silent --show-error --max-time 5 \
        --header "content-type: application/json" \
        --data-binary @- \
        --write-out "%{http_code}" \
        --output /dev/null \
        "${SPEC_SERVER_URL}${path}" \
    || echo "000")
  if [ "$http_code" != "200" ] && [ "$http_code" != "204" ]; then
    say "WARN spec POST $path -> $http_code (body=$body)"
  fi
}

die_failed() {
  local msg="$1"
  say "ERROR: $msg"
  api_status "status=error" "error=${msg}"
  exit 1
}

SAVED_TICK=""
SAVED_PAUSED=""
restore_user_playback() {
  if [ -z "$SAVED_TICK" ]; then return 0; fi
  spec_post /demo/pause '{"force": true}'
  spec_post /demo/seek "{\"tick\": ${SAVED_TICK}}"
  if [ "$SAVED_PAUSED" != "true" ]; then
    spec_post /demo/toggle '{}'
  fi
}

on_exit() {
  if [ "${LIVE_CAPTURE_STOPPED:-0}" = "1" ] && [ -n "${MATCH_ID:-}" ]; then
    restart_capture "$MATCH_ID" || true
    LIVE_CAPTURE_STOPPED=0
  fi
  restore_user_playback
}
trap 'on_exit' EXIT

log_state() {
  local label="$1"
  local s tick paused
  s=$(spec_get_state || true)
  if [ -z "$s" ]; then
    say "STATE [$label]: <unreachable>"
    return
  fi
  tick=$(printf '%s' "$s" | python3 -c \
    'import json,sys; d=json.load(sys.stdin); print(d.get("tick","?"))')
  paused=$(printf '%s' "$s" | python3 -c \
    'import json,sys; d=json.load(sys.stdin); print(d.get("paused","?"))')
  say "STATE [$label]: tick=$tick paused=$paused"
}

# True if the captured mp4 has an audio stream that ffmpeg can read.
has_audio_stream() {
  local f="$1"
  ffprobe -v error -select_streams a -show_entries stream=codec_type \
    -of csv=p=0 "$f" 2>/dev/null | grep -q audio
}

say "============================================================"
say "SPEED=${CLIP_RENDER_SPEED}x  ticks=${CLIP_START_TICK}..${CLIP_END_TICK}  output=${CLIP_OUTPUT_DIMS:-?}@${CLIP_OUTPUT_FPS:-?}"
say "============================================================"
api_status "status=rendering" "progress=0.02"

say "STEP 1: snapshot"
STATE_JSON=$(spec_get_state || true)
if [ -z "$STATE_JSON" ]; then
  die_failed "spec-server /demo/state unreachable"
fi
SAVED_TICK=$(printf '%s' "$STATE_JSON" | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print(d.get("tick",0))')
SAVED_PAUSED=$(printf '%s' "$STATE_JSON" | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print(str(d.get("paused",False)).lower())')
say "STEP 1: tick=$SAVED_TICK paused=$SAVED_PAUSED"
api_status "status=rendering" "progress=0.05"

say "STEP 2: force-pause"
spec_post /demo/pause '{"force": true}'

say "STEP 3: seek to $CLIP_START_TICK"
spec_post /demo/seek "{\"tick\": ${CLIP_START_TICK}}"
api_status "status=rendering" "progress=0.06"

# re-pause after the lead-in: some cs2 builds auto-resume on demo_gototick
say "STEP 4: lead-in 2s + re-pause"
sleep 2
spec_post /demo/pause '{"force": true}'
api_status "status=rendering" "progress=0.08"

LIVE_CAPTURE_STOPPED=0
if [ -n "${MATCH_ID:-}" ]; then
  say "STEP 5a: stop live capture for $MATCH_ID"
  stop_capture "$MATCH_ID"
  LIVE_CAPTURE_STOPPED=1
fi

CLIP_OUT_DIR="${CLIP_OUT_DIR:-/tmp/game-streamer/clips}"
mkdir -p "$CLIP_OUT_DIR"
CLIP_OUT_FILE="${CLIP_OUT_DIR}/${CLIP_RENDER_JOB_ID}.mp4"
rm -f "$CLIP_OUT_FILE"

DURATION_TICKS=$((CLIP_END_TICK - CLIP_START_TICK))
DURATION_MS=$(awk -v t="$DURATION_TICKS" -v r="${CLIP_TICK_RATE:-64}" \
  'BEGIN{printf "%d", t / r * 1000}')

say "STEP 5b: start GStreamer file capture"
if ! start_clip_capture "$CLIP_OUT_FILE" "${CLIP_OUTPUT_FPS:-60}" 8000 1; then
  [ "$LIVE_CAPTURE_STOPPED" = "1" ] && restart_capture "$MATCH_ID"
  die_failed "clip capture failed to start"
fi
say "STEP 5b: pid=${CLIP_CAPTURE_PID:-?}"
api_status "status=rendering" "progress=0.10"

# /demo/toggle is the only resume path that's reliable across cs2 builds.
say "STEP 6: PRESS PLAY"
spec_post /demo/toggle '{}'

# demo_timescale is the cs2 cvar that actually scales DEMO playback
# rate. host_timescale affects engine wallclock and isn't always 2x in
# practice — captured content was running ~1.7x and the ffmpeg 2x
# slowdown then pushed it into slow-motion.
if [ "$CLIP_RENDER_SPEED" != "1" ]; then
  spec_post /demo/exec "{\"cmd\": \"demo_timescale ${CLIP_RENDER_SPEED}\"}"
fi

WALLCLOCK_MS=$((DURATION_MS / CLIP_RENDER_SPEED))
say "STEP 7: capturing ${DURATION_MS}ms in ${WALLCLOCK_MS}ms wallclock"

ELAPSED_MS=0
LAST_STATE_LOG=0
while [ "$ELAPSED_MS" -lt "$WALLCLOCK_MS" ]; do
  if ! kill -0 "${CLIP_CAPTURE_PID:-0}" 2>/dev/null; then
    die_failed "clip capture died mid-render"
  fi
  if [ $((ELAPSED_MS - LAST_STATE_LOG)) -ge 5000 ]; then
    log_state "capture +${ELAPSED_MS}ms"
    LAST_STATE_LOG=$ELAPSED_MS
  fi
  REMAINING=$((WALLCLOCK_MS - ELAPSED_MS))
  STEP=$((REMAINING < 2000 ? REMAINING : 2000))
  sleep "$(awk -v s="$STEP" 'BEGIN{printf "%.3f", s/1000}')"
  ELAPSED_MS=$((ELAPSED_MS + STEP))
  FRAC=$(awk -v e="$ELAPSED_MS" -v d="$WALLCLOCK_MS" \
    'BEGIN{printf "%.3f", 0.10 + 0.40 * e / d}')
  api_status "status=rendering" "progress=$FRAC"
done

if [ "$CLIP_RENDER_SPEED" != "1" ]; then
  spec_post /demo/exec '{"cmd": "demo_timescale 1"}'
fi

say "STEP 8: stop capture"
stop_clip_capture

# atempo per-instance range is 0.5..100, so >2x slowdown needs chained filters.
if [ "$CLIP_RENDER_SPEED" != "1" ]; then
  case "$CLIP_RENDER_SPEED" in
    2) ATEMPO_FILTER="atempo=0.5" ;;
    3) ATEMPO_FILTER="atempo=0.5,atempo=0.667" ;;
    4) ATEMPO_FILTER="atempo=0.5,atempo=0.5" ;;
    *) ATEMPO_FILTER="atempo=0.5" ;;
  esac

  HAS_AUDIO=0
  if has_audio_stream "$CLIP_OUT_FILE"; then HAS_AUDIO=1; fi

  SLOWDOWN_FILE="${CLIP_OUT_FILE}.slow.mp4"
  AUDIO_ARGS=()
  if [ "$HAS_AUDIO" = "1" ]; then
    AUDIO_ARGS=(-af "$ATEMPO_FILTER" -c:a aac -b:a 192k)
    say "STEP 8b: ffmpeg slowdown ${CLIP_RENDER_SPEED}x (with audio: $ATEMPO_FILTER)"
  else
    AUDIO_ARGS=(-an)
    say "STEP 8b: ffmpeg slowdown ${CLIP_RENDER_SPEED}x (no audio in source)"
  fi

  if ! ffmpeg -y -hide_banner -loglevel warning \
       -i "$CLIP_OUT_FILE" \
       -vf "setpts=${CLIP_RENDER_SPEED}*PTS" \
       "${AUDIO_ARGS[@]}" \
       -c:v libx264 -preset veryfast -crf 22 \
       -movflags +faststart \
       "$SLOWDOWN_FILE"; then
    say "STEP 8b: slowdown with audio failed — retrying without audio"
    rm -f "$SLOWDOWN_FILE"
    if ! ffmpeg -y -hide_banner -loglevel warning \
         -i "$CLIP_OUT_FILE" \
         -vf "setpts=${CLIP_RENDER_SPEED}*PTS" \
         -an \
         -c:v libx264 -preset veryfast -crf 22 \
         -movflags +faststart \
         "$SLOWDOWN_FILE"; then
      rm -f "$SLOWDOWN_FILE"
      die_failed "ffmpeg slowdown failed"
    fi
  fi
  mv -f "$SLOWDOWN_FILE" "$CLIP_OUT_FILE"
fi

if [ "$LIVE_CAPTURE_STOPPED" = "1" ] && [ -n "${MATCH_ID:-}" ]; then
  say "STEP 8c: restart live capture"
  restart_capture "$MATCH_ID"
  LIVE_CAPTURE_STOPPED=0
fi
api_status "status=rendering" "progress=0.50"

restore_user_playback
SAVED_TICK=""
trap - EXIT

[ -s "$CLIP_OUT_FILE" ] || die_failed "clip output is empty"
CLIP_BYTES=$(stat -c '%s' "$CLIP_OUT_FILE" 2>/dev/null \
  || stat -f '%z' "$CLIP_OUT_FILE")
say "rendered $CLIP_OUT_FILE ($CLIP_BYTES bytes)"
REAL_DURATION_MS=$(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 "$CLIP_OUT_FILE" 2>/dev/null \
  | awk '{printf "%d", $1 * 1000}')
[ -z "$REAL_DURATION_MS" ] && REAL_DURATION_MS="$DURATION_MS"

api_status "status=uploading" "progress=0.50"
UPLOAD_URL="${STATUS_API_BASE}/clip-renders/${CLIP_RENDER_JOB_ID}/upload"
say "POST $UPLOAD_URL"
if ! curl --fail --silent --show-error \
       --max-time 1800 \
       --header "x-origin-auth: ${CLIP_RENDER_JOB_ID}:${CLIP_RENDER_TOKEN}" \
       --header "content-type: application/octet-stream" \
       --header "x-clip-duration-ms: ${REAL_DURATION_MS}" \
       --data-binary "@${CLIP_OUT_FILE}" \
       --output /tmp/clip-upload-response.json \
       "$UPLOAD_URL"; then
  die_failed "clip upload failed"
fi

api_status "status=done" "progress=1.0"
rm -f "$CLIP_OUT_FILE"
say "done"
