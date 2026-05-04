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

# Read GSI's currently-spectated steamid64 from /demo/state. Returns
# empty string when GSI hasn't fired yet or the field isn't set.
gsi_spectated_steamid() {
  local s
  s=$(spec_get_state || true)
  [ -z "$s" ] && { echo ""; return; }
  printf '%s' "$s" \
    | python3 -c \
      'import json,sys
try:
    d = json.load(sys.stdin)
    print(d.get("gsi", {}).get("spectated_steam_id", "") or "")
except Exception:
    print("")'
}

# Look up the target's CURRENT slot number (1..10) from GSI's
# spec_slots block. cs2 reassigns observer_slot per round, so we
# can't compute this once — must read fresh each segment.
gsi_slot_for_steamid() {
  local target_sid="$1"
  local s
  s=$(spec_get_state || true)
  [ -z "$s" ] && { echo ""; return; }
  printf '%s' "$s" \
    | python3 -c \
      "import json,sys
try:
    d = json.load(sys.stdin)
    target = '$target_sid'
    for s in d.get('gsi', {}).get('spec_slots', []):
        if s.get('steam_id') == target:
            print(s['slot'])
            sys.exit(0)
except Exception:
    pass
print('')"
}

# Force cs2 onto a specific player and confirm via GSI before
# returning.
#
# Why slot-key instead of spec_player_by_accountid: in practice cs2
# silently no-ops the by_accountid command for demo playback (we
# verified this from logs — the command runs, GSI never updates).
# The digit-key path is what the live stream-deck slot buttons use,
# and it actually drives cs2's spec switcher. We look up the
# target's CURRENT observer_slot in GSI, press that digit, then
# poll until GSI confirms.
#
# Args: <expected-steamid64>
# Returns 0 on confirmed lock, 1 if it never confirmed.
verify_spec_lock() {
  local target_sid="$1"
  local slot=""
  # Find slot — retry briefly in case GSI is between snapshots.
  local try
  for try in 1 2 3 4 5; do
    slot=$(gsi_slot_for_steamid "$target_sid")
    if [ -n "$slot" ]; then break; fi
    sleep 0.2
  done
  if [ -z "$slot" ]; then
    say "WARN target ${target_sid} is not in GSI spec_slots — POV lock skipped"
    return 1
  fi
  say "  pressing digit key for slot ${slot} -> ${target_sid}"
  spec_post /spec/slot "{\"slot\": ${slot}}"
  # Up to 2s of polling at ~7Hz. cs2 GSI fires at ~10Hz so 150ms
  # gives the next tick a chance to land between polls.
  local i current
  for i in $(seq 1 14); do
    sleep 0.15
    current=$(gsi_spectated_steamid)
    if [ "$current" = "$target_sid" ]; then
      say "  POV verified via GSI: spectated=${current}"
      return 0
    fi
  done
  say "WARN POV did not verify after 2s — wanted=${target_sid} got='${current}' — re-pressing slot ${slot}"
  spec_post /spec/slot "{\"slot\": ${slot}}"
  for i in $(seq 1 14); do
    sleep 0.15
    current=$(gsi_spectated_steamid)
    if [ "$current" = "$target_sid" ]; then
      say "  POV verified after retry: spectated=${current}"
      return 0
    fi
  done
  say "WARN POV still not locked to ${target_sid} (got '${current}') — proceeding anyway"
  return 1
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

# Pre-render cancel check. The user (or admin) can hit cancel on a
# queued/in-flight clip while we're still booting cs2 / processing
# the previous batch entry; the api flips status='cancelled' and we
# read it back here. Skipping cleanly with exit 0 keeps batch-mode
# moving to the next clip without an error log.
api_check_status() {
  curl --fail --silent --show-error --max-time 5 \
       --header "x-origin-auth: ${CLIP_RENDER_JOB_ID}:${CLIP_RENDER_TOKEN}" \
       "${STATUS_API_BASE}/clip-renders/${CLIP_RENDER_JOB_ID}/status" \
    || echo ""
}
PRE_STATUS_RAW=$(api_check_status)
PRE_STATUS=$(printf '%s' "$PRE_STATUS_RAW" | python3 -c \
  'import json,sys
try:
    d = json.load(sys.stdin)
    print(d.get("status",""))
except Exception:
    print("")' 2>/dev/null || echo "")
if [ "$PRE_STATUS" = "cancelled" ]; then
  say "job already cancelled by user — skipping (no work, no error)"
  exit 0
fi

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
# Progress is now reported as RENDER-PHASE 0..1 (not stitched into a
# global 0..1 that smushed render + upload together). The web shows
# render and upload as two independent bars now: render shows live %
# while status='rendering', upload renders as an indeterminate spinner
# while status='uploading'. We don't have real upload bytes-progress
# (single curl POST, no streaming readback), so the upload bar is
# intentionally pulse-only. Setup overhead before any segment plays
# stays at the front of the render bar (BASE=0.05).
PROGRESS_BASE=0.05
PROGRESS_SPAN=0.95
ELAPSED_TICKS_TOTAL=0

for SEG_IDX in $(seq 0 $((SEG_COUNT - 1))); do
  SEG_START=$(printf '%s' "$CLIP_SEGMENTS" | python3 -c \
    "import json,sys; print(json.load(sys.stdin)[$SEG_IDX]['start_tick'])")
  SEG_END=$(printf '%s' "$CLIP_SEGMENTS" | python3 -c \
    "import json,sys; print(json.load(sys.stdin)[$SEG_IDX]['end_tick'])")
  # POV target. cs2's spec_player_by_accountid takes the 32-bit
  # accountid (steamid64 - 76561197960265728). We send the lock
  # AFTER seeking + lead-in so cs2's freshly-seeked spec target
  # gets overridden onto the player whose kills we're rendering.
  # Without this, the demo opens with whoever cs2 was last
  # spectating, which produces a clip from the wrong POV.
  SEG_POV_ACCOUNTID=$(printf '%s' "$CLIP_SEGMENTS" | python3 -c \
    "
import json,sys
seg = json.load(sys.stdin)[$SEG_IDX]
sid = seg.get('pov_steam_id')
if isinstance(sid, str) and sid.isdigit():
    aid = int(sid) - 76561197960265728
    if aid > 0:
        print(aid)
")
  SEG_TICKS=$((SEG_END - SEG_START))
  SEG_DURATION_MS=$(awk -v t="$SEG_TICKS" -v r="${CLIP_TICK_RATE:-64}" \
    'BEGIN{printf "%d", t / r * 1000}')
  SEG_FILE="${SEG_DIR}/seg-$(printf '%03d' "$SEG_IDX").mp4"
  say "------- SEGMENT $((SEG_IDX + 1))/${SEG_COUNT}: ticks=${SEG_START}..${SEG_END} (${SEG_DURATION_MS}ms)"

  say "STEP 2: force-pause"
  spec_post /demo/pause '{"force": true}'
  say "STEP 3: seek to $SEG_START"
  spec_post /demo/seek "{\"tick\": ${SEG_START}}"

  # Lead-in: unpause briefly so cs2 actually processes the seek AND
  # the upcoming spec command. Spec commands no-op while paused on
  # most cs2 builds — that's why the previous "lock then play" order
  # was capturing the wrong POV. Now the order is:
  #   seek → unpause → spec lock + GSI verify → re-pause → start
  #   capture → unpause → GO.
  say "STEP 4: lead-in (unpaused) — seek settle"
  spec_post /demo/toggle '{}'
  sleep 0.6

  if [ -n "$SEG_POV_ACCOUNTID" ]; then
    SEG_POV_STEAMID=$((SEG_POV_ACCOUNTID + 76561197960265728))
    say "STEP 4b: lock POV to steamid=${SEG_POV_STEAMID}"
    verify_spec_lock "$SEG_POV_STEAMID" || true
  fi

  # Re-pause AND re-seek back to SEG_START. The lead-in unpause +
  # GSI poll consumed real demo time (up to ~3s of ticks); capturing
  # from "wherever we ended up" would chop off the start of every
  # segment and could push us past the first kill entirely. The
  # 0.2s settle is the minimum cs2 needs to land the new tick AND
  # re-render the frame — anything less and we sometimes capture
  # a stale frame from before the seek.
  spec_post /demo/pause '{"force": true}'
  spec_post /demo/seek "{\"tick\": ${SEG_START}}"
  sleep 0.2

  # Re-press the slot key BEFORE starting capture. The re-seek
  # above commonly resets cs2's spec target on this build; firing
  # the digit key here queues the next press for when play resumes
  # so the first captured frame is the right POV.
  if [ -n "${SEG_POV_STEAMID:-}" ]; then
    POV_SLOT_AFTER_SEEK=$(gsi_slot_for_steamid "$SEG_POV_STEAMID")
    if [ -n "$POV_SLOT_AFTER_SEEK" ]; then
      spec_post /spec/slot "{\"slot\": ${POV_SLOT_AFTER_SEEK}}"
    fi
  fi

  say "STEP 5: start GStreamer file capture -> $SEG_FILE"
  if ! start_clip_capture "$SEG_FILE" "${CLIP_OUTPUT_FPS:-60}" 8000 1; then
    die_failed "clip capture failed to start (segment $SEG_IDX)"
  fi
  say "STEP 5: pid=${CLIP_CAPTURE_PID:-?}"

  say "STEP 6: PRESS PLAY"
  spec_post /demo/toggle '{}'

  # Belt-and-suspenders: press the slot digit one more time right
  # after play resumes. The freshest GSI snapshot may have moved
  # the player to a different observer_slot since the round started
  # rolling, so re-look it up rather than cache.
  if [ -n "${SEG_POV_STEAMID:-}" ]; then
    POV_SLOT_AFTER_PLAY=$(gsi_slot_for_steamid "$SEG_POV_STEAMID")
    if [ -n "$POV_SLOT_AFTER_PLAY" ]; then
      spec_post /spec/slot "{\"slot\": ${POV_SLOT_AFTER_PLAY}}"
    fi
  fi

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

  # Sanity check: capture sometimes produces an mp4 with no
  # decodable frames (cs2 mid-load, audio attach race, etc).
  # Concat'ing an empty file silently drops everything after it,
  # which is exactly the "got 1 kill instead of 2" bug. Probe the
  # file and skip from concat if unusable — better to lose a beat
  # than the rest of the highlight.
  SEG_BYTES=$(stat -c '%s' "$SEG_FILE" 2>/dev/null \
    || stat -f '%z' "$SEG_FILE" 2>/dev/null \
    || echo 0)
  SEG_REAL_DUR=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$SEG_FILE" 2>/dev/null \
    | awk '{printf "%.2f", $1}')
  [ -z "$SEG_REAL_DUR" ] && SEG_REAL_DUR=0
  IS_VALID=$(awk -v d="$SEG_REAL_DUR" -v b="$SEG_BYTES" \
    'BEGIN{print (d >= 0.5 && b > 1024) ? 1 : 0}')
  if [ "$IS_VALID" = "1" ]; then
    say "  segment $SEG_IDX OK (${SEG_BYTES}B, ${SEG_REAL_DUR}s)"
    printf "file '%s'\n" "$SEG_FILE" >>"$SEG_DIR/concat.txt"
  else
    say "WARN segment $SEG_IDX is empty/short (${SEG_BYTES}B, ${SEG_REAL_DUR}s) — dropping from concat"
    rm -f "$SEG_FILE"
  fi
  ELAPSED_TICKS_TOTAL=$((ELAPSED_TICKS_TOTAL + SEG_TICKS))
done

# Recompute SEG_COUNT from what actually ended up in concat.txt —
# downstream fade pass + concat decisions need the real count, not
# the originally-requested count.
SEG_COUNT=$(grep -c "^file " "$SEG_DIR/concat.txt" 2>/dev/null || echo 0)
if [ "$SEG_COUNT" -lt 1 ]; then
  die_failed "all segments produced empty captures — cs2 may be stalled"
fi

# Concat — direct cuts between segments. We tried 0.4s fade
# transitions earlier and the result was a longer-than-expected dip
# to black at every join (cs2's seek-loading frames at the head of
# each segment compound with the fade-in, producing 0.5-1s of dead
# air per cut). For a frag montage the harder pace of direct cuts
# reads better and the action stays continuous.
if [ "$SEG_COUNT" = "1" ]; then
  ONLY_SEG=$(awk -F"'" '/^file/{print $2}' "$SEG_DIR/concat.txt" | head -1)
  mv -f "$ONLY_SEG" "$CLIP_OUT_FILE"
else
  say "STEP 9: ffmpeg concat ${SEG_COUNT} segments (direct cuts)"
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
api_status "status=rendering" "progress=1.0"

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

api_status "status=uploading" "progress=0.0"
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
