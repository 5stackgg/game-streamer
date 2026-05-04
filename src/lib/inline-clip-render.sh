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
            SPEC_SERVER_URL

CLIP_RENDER_SPEED="${CLIP_RENDER_SPEED:-1}"

# Multi-segment input. CLIP_SEGMENTS is a JSON array of
# {start_tick,end_tick} from the api; each one is captured separately
# and the results are concatenated by ffmpeg into the final mp4.
# Falls back to the legacy single-segment env vars when unset so
# operators / tests that still pass CLIP_START_TICK / CLIP_END_TICK
# keep working.
if [ -z "${CLIP_SEGMENTS:-}" ]; then
  if [ -z "${CLIP_START_TICK:-}" ] || [ -z "${CLIP_END_TICK:-}" ]; then
    echo "[clip] CLIP_SEGMENTS or CLIP_START_TICK/CLIP_END_TICK required" >&2
    exit 1
  fi
  CLIP_SEGMENTS="[{\"start_tick\":${CLIP_START_TICK},\"end_tick\":${CLIP_END_TICK}}]"
fi

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

# Parse segments + compute total duration for progress weighting.
SEG_COUNT=$(printf '%s' "$CLIP_SEGMENTS" | python3 -c \
  'import json,sys; print(len(json.load(sys.stdin)))')
if [ "$SEG_COUNT" -lt 1 ]; then
  die_failed "CLIP_SEGMENTS contains zero segments"
fi
TOTAL_DURATION_TICKS=$(printf '%s' "$CLIP_SEGMENTS" | python3 -c \
  'import json,sys
segs = json.load(sys.stdin)
print(sum(max(0, s["end_tick"] - s["start_tick"]) for s in segs))')

say "============================================================"
say "SPEED=${CLIP_RENDER_SPEED}x  segments=${SEG_COUNT}  total_ticks=${TOTAL_DURATION_TICKS}  output=${CLIP_OUTPUT_DIMS:-?}@${CLIP_OUTPUT_FPS:-?}"
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

LIVE_CAPTURE_STOPPED=0
if [ -n "${MATCH_ID:-}" ]; then
  say "STEP 1a: stop live capture for $MATCH_ID"
  stop_capture "$MATCH_ID"
  LIVE_CAPTURE_STOPPED=1
fi

CLIP_OUT_DIR="${CLIP_OUT_DIR:-/tmp/game-streamer/clips}"
mkdir -p "$CLIP_OUT_DIR"
CLIP_OUT_FILE="${CLIP_OUT_DIR}/${CLIP_RENDER_JOB_ID}.mp4"
rm -f "$CLIP_OUT_FILE"

# Per-segment output paths + concat list. We render each segment to
# its own file and let ffmpeg concat-demux glue them — this keeps each
# capture session independent (a stall in one doesn't ruin the rest)
# and isolates the speed-correction ffmpeg pass per segment.
SEG_DIR="${CLIP_OUT_DIR}/${CLIP_RENDER_JOB_ID}.segs"
mkdir -p "$SEG_DIR"
rm -f "$SEG_DIR"/*.mp4 "$SEG_DIR/concat.txt" 2>/dev/null || true
: >"$SEG_DIR/concat.txt"

# Capture phase = 0.10 → 0.85 of overall progress (the rest is
# concat + upload). Per-segment slice of that band is proportional to
# segment ticks.
PROGRESS_BASE=0.10
PROGRESS_SPAN=0.75
ELAPSED_TICKS_TOTAL=0

for SEG_IDX in $(seq 0 $((SEG_COUNT - 1))); do
  SEG_START=$(printf '%s' "$CLIP_SEGMENTS" | python3 -c \
    "import json,sys; print(json.load(sys.stdin)[$SEG_IDX]['start_tick'])")
  SEG_END=$(printf '%s' "$CLIP_SEGMENTS" | python3 -c \
    "import json,sys; print(json.load(sys.stdin)[$SEG_IDX]['end_tick'])")
  SEG_TICKS=$((SEG_END - SEG_START))
  SEG_DURATION_MS=$(awk -v t="$SEG_TICKS" -v r="${CLIP_TICK_RATE:-64}" \
    'BEGIN{printf "%d", t / r * 1000}')
  SEG_FILE="${SEG_DIR}/seg-$(printf '%03d' "$SEG_IDX").mp4"
  say "------- SEGMENT $((SEG_IDX + 1))/${SEG_COUNT}: ticks=${SEG_START}..${SEG_END} (${SEG_DURATION_MS}ms)"

  say "STEP 2: force-pause"
  spec_post /demo/pause '{"force": true}'
  say "STEP 3: seek to $SEG_START"
  spec_post /demo/seek "{\"tick\": ${SEG_START}}"
  # cs2 sometimes auto-resumes on demo_gototick; lead-in lets the
  # frame land + lets us re-pause cleanly before rolling capture.
  say "STEP 4: lead-in 2s + re-pause"
  sleep 2
  spec_post /demo/pause '{"force": true}'

  say "STEP 5b: start GStreamer file capture -> $SEG_FILE"
  if ! start_clip_capture "$SEG_FILE" "${CLIP_OUTPUT_FPS:-60}" 8000 1; then
    die_failed "clip capture failed to start (segment $SEG_IDX)"
  fi
  say "STEP 5b: pid=${CLIP_CAPTURE_PID:-?}"

  say "STEP 6: PRESS PLAY"
  spec_post /demo/toggle '{}'

  if [ "$CLIP_RENDER_SPEED" != "1" ]; then
    spec_post /demo/exec "{\"cmd\": \"demo_timescale ${CLIP_RENDER_SPEED}\"}"
  fi

  WALLCLOCK_MS=$((SEG_DURATION_MS / CLIP_RENDER_SPEED))
  say "STEP 7: capturing ${SEG_DURATION_MS}ms in ${WALLCLOCK_MS}ms wallclock"

  ELAPSED_MS=0
  LAST_STATE_LOG=0
  while [ "$ELAPSED_MS" -lt "$WALLCLOCK_MS" ]; do
    if ! kill -0 "${CLIP_CAPTURE_PID:-0}" 2>/dev/null; then
      die_failed "clip capture died mid-render (segment $SEG_IDX)"
    fi
    if [ $((ELAPSED_MS - LAST_STATE_LOG)) -ge 5000 ]; then
      log_state "seg${SEG_IDX} +${ELAPSED_MS}ms"
      LAST_STATE_LOG=$ELAPSED_MS
    fi
    REMAINING=$((WALLCLOCK_MS - ELAPSED_MS))
    STEP=$((REMAINING < 2000 ? REMAINING : 2000))
    sleep "$(awk -v s="$STEP" 'BEGIN{printf "%.3f", s/1000}')"
    ELAPSED_MS=$((ELAPSED_MS + STEP))
    # Progress: base + span * (segments_done_ticks + current_seg_progress) / total_ticks
    DONE_FRAC=$(awk \
      -v base="$PROGRESS_BASE" -v span="$PROGRESS_SPAN" \
      -v done_ticks="$ELAPSED_TICKS_TOTAL" \
      -v cur_e="$ELAPSED_MS" -v cur_w="$WALLCLOCK_MS" \
      -v cur_ticks="$SEG_TICKS" -v total="$TOTAL_DURATION_TICKS" \
      'BEGIN{
         partial = (cur_w > 0) ? (cur_ticks * cur_e / cur_w) : cur_ticks;
         printf "%.3f", base + span * (done_ticks + partial) / total;
       }')
    api_status "status=rendering" "progress=$DONE_FRAC"
  done

  if [ "$CLIP_RENDER_SPEED" != "1" ]; then
    spec_post /demo/exec '{"cmd": "demo_timescale 1"}'
  fi

  say "STEP 8: stop capture (segment $SEG_IDX)"
  stop_clip_capture

  # Per-segment slowdown so the concat input is already at real-time.
  if [ "$CLIP_RENDER_SPEED" != "1" ]; then
    case "$CLIP_RENDER_SPEED" in
      2) ATEMPO_FILTER="atempo=0.5" ;;
      3) ATEMPO_FILTER="atempo=0.5,atempo=0.667" ;;
      4) ATEMPO_FILTER="atempo=0.5,atempo=0.5" ;;
      *) ATEMPO_FILTER="atempo=0.5" ;;
    esac
    HAS_AUDIO=0
    if has_audio_stream "$SEG_FILE"; then HAS_AUDIO=1; fi
    SLOW_FILE="${SEG_FILE}.slow.mp4"
    AUDIO_ARGS=()
    if [ "$HAS_AUDIO" = "1" ]; then
      AUDIO_ARGS=(-af "$ATEMPO_FILTER" -c:a aac -b:a 192k)
    else
      AUDIO_ARGS=(-an)
    fi
    if ! ffmpeg -y -hide_banner -loglevel warning \
         -i "$SEG_FILE" \
         -vf "setpts=${CLIP_RENDER_SPEED}*PTS" \
         "${AUDIO_ARGS[@]}" \
         -c:v libx264 -preset veryfast -crf 22 \
         -movflags +faststart \
         "$SLOW_FILE"; then
      rm -f "$SLOW_FILE"
      die_failed "ffmpeg slowdown failed (segment $SEG_IDX)"
    fi
    mv -f "$SLOW_FILE" "$SEG_FILE"
  fi

  printf "file '%s'\n" "$SEG_FILE" >>"$SEG_DIR/concat.txt"
  ELAPSED_TICKS_TOTAL=$((ELAPSED_TICKS_TOTAL + SEG_TICKS))
done

# Concat. With one segment we can copy streams; with multiple we
# re-encode to avoid edge-case PTS / SAR mismatches between captures
# (e.g. an i-frame that landed at a different offset between segments
# would hard-cut on copy).
if [ "$SEG_COUNT" = "1" ]; then
  ONLY_SEG=$(awk -F"'" '/^file/{print $2}' "$SEG_DIR/concat.txt" | head -1)
  mv -f "$ONLY_SEG" "$CLIP_OUT_FILE"
else
  say "STEP 9: ffmpeg concat ${SEG_COUNT} segments"
  if ! ffmpeg -y -hide_banner -loglevel warning \
       -f concat -safe 0 -i "$SEG_DIR/concat.txt" \
       -c:v libx264 -preset veryfast -crf 22 \
       -c:a aac -b:a 192k \
       -movflags +faststart \
       "$CLIP_OUT_FILE"; then
    die_failed "ffmpeg concat failed"
  fi
fi
rm -rf "$SEG_DIR"

if [ "$LIVE_CAPTURE_STOPPED" = "1" ] && [ -n "${MATCH_ID:-}" ]; then
  say "STEP 9a: restart live capture"
  restart_capture "$MATCH_ID"
  LIVE_CAPTURE_STOPPED=0
fi
api_status "status=rendering" "progress=0.90"

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
if [ -z "$REAL_DURATION_MS" ]; then
  REAL_DURATION_MS=$(awk -v t="$TOTAL_DURATION_TICKS" -v r="${CLIP_TICK_RATE:-64}" \
    'BEGIN{printf "%d", t / r * 1000}')
fi

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
