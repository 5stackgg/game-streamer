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
# Per-segment hard cap on the capture loop, expressed as a multiple of
# the expected wallclock. The loop already terminates at WALLCLOCK_MS;
# this is belt-and-suspenders against `kill -0` mis-reporting + the
# (rare) case where gst keeps the capture pid alive past EOS.
CLIP_SEGMENT_TIMEOUT_FACTOR="${CLIP_SEGMENT_TIMEOUT_FACTOR:-3}"

CLIP_HELPERS="$LIB_DIR/clip-helpers.mjs"

LOG_PREFIX="[clip ${CLIP_RENDER_JOB_ID:0:8}]"
say() { printf '%s %s\n' "$LOG_PREFIX" "$*" >&2; }

api_status() {
  local body
  body=$(node "$CLIP_HELPERS" status-body "$@")
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
  local body="${1:-{\}}"
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
  CLIP_REACHED_TERMINAL=1
  exit 1
}

# Flag flipped to 1 once we've POSTed a terminal status (done / error /
# cancelled). The on_exit trap inspects it: if the script exits without
# having reached terminal — `set -u` tripped on an unset var,
# inline-clip-render.sh got SIGTERM mid-render, etc — the trap POSTs a
# best-effort status=error so the watchdog isn't left staring at a row
# stuck in "rendering" while the pod has already moved on / exited.
# Without this, batch-highlights pods could finish all 10 jobs in
# subshells that died early and exit 0 with every row still in-flight,
# producing the "pod exited cleanly but N job(s) never reached terminal
# state" warning in the api log.
CLIP_REACHED_TERMINAL=0

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
  local rc=$?
  if [ "${LIVE_CAPTURE_STOPPED:-0}" = "1" ] && [ -n "${MATCH_ID:-}" ]; then
    restart_capture "$MATCH_ID" || true
    LIVE_CAPTURE_STOPPED=0
  fi
  # ProRes intermediates are ~20MB/s — drop the chip mov even on
  # error so a flapping pod doesn't fill its scratch dir.
  if [ -n "${CHIP_MOV:-}" ]; then rm -f "$CHIP_MOV"; fi
  restore_user_playback
  # Belt-and-suspenders status report. If we exited without having
  # POSTed a terminal status (set -u trip, SIGTERM, early exit before
  # die_failed was reachable), best-effort mark the row error so the
  # batch-highlights watchdog doesn't leave it stuck in-flight.
  if [ "$rc" -ne 0 ] && [ "${CLIP_REACHED_TERMINAL:-0}" != "1" ]; then
    api_status "status=error" "error=render exited rc=${rc} before reaching terminal status" \
      || true
  fi
}
trap 'on_exit' EXIT

# Multi-segment input. CLIP_SEGMENTS is a JSON array of
# {start_tick,end_tick} from the api; each one is captured separately
# and the results are concatenated by ffmpeg into the final mp4.
# Falls back to the legacy single-segment env vars when unset so
# operators / tests that still pass CLIP_START_TICK / CLIP_END_TICK
# keep working. Resolved AFTER die_failed + the EXIT trap are in place
# so a misconfigured invocation marks the row error instead of leaving
# it stuck in "queued" while the pod exits cleanly.
if [ -z "${CLIP_SEGMENTS:-}" ]; then
  if [ -z "${CLIP_START_TICK:-}" ] || [ -z "${CLIP_END_TICK:-}" ]; then
    die_failed "CLIP_SEGMENTS or CLIP_START_TICK/CLIP_END_TICK required"
  fi
  CLIP_SEGMENTS="[{\"start_tick\":${CLIP_START_TICK},\"end_tick\":${CLIP_END_TICK}}]"
fi

log_state() {
  local label="$1"
  local s tick paused
  s=$(spec_get_state || true)
  if [ -z "$s" ]; then
    say "STATE [$label]: <unreachable>"
    return
  fi
  tick=$(printf '%s' "$s" | node "$CLIP_HELPERS" state-tick)
  paused=$(printf '%s' "$s" | node "$CLIP_HELPERS" state-paused)
  say "STATE [$label]: tick=$tick paused=$paused"
}

# Read GSI's currently-spectated steamid64 from /demo/state. Returns
# empty string when GSI hasn't fired yet or the field isn't set.
gsi_spectated_steamid() {
  local s
  s=$(spec_get_state || true)
  [ -z "$s" ] && { echo ""; return; }
  printf '%s' "$s" | node "$CLIP_HELPERS" spectated-steamid
}

# Look up the target's CURRENT slot number (1..10) from GSI's
# spec_slots block. cs2 reassigns observer_slot per round, so we
# can't compute this once — must read fresh each segment.
gsi_slot_for_steamid() {
  local target_sid="$1"
  local s
  s=$(spec_get_state || true)
  [ -z "$s" ] && { echo ""; return; }
  printf '%s' "$s" | node "$CLIP_HELPERS" slot-for-steamid "$target_sid"
}

# Lock cs2 onto a specific player and confirm via GSI. Uses the
# digit-key (slot) path because spec_player_by_accountid silently
# no-ops on demo playback (verified — command runs, GSI never updates).
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
SEG_COUNT=$(printf '%s' "$CLIP_SEGMENTS" | node "$CLIP_HELPERS" segs-count)
if [ "$SEG_COUNT" -lt 1 ]; then
  die_failed "CLIP_SEGMENTS contains zero segments"
fi
TOTAL_DURATION_TICKS=$(printf '%s' "$CLIP_SEGMENTS" \
  | node "$CLIP_HELPERS" segs-total-ticks)

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
PRE_STATUS=$(printf '%s' "$PRE_STATUS_RAW" | node "$CLIP_HELPERS" status-field)
if [ "$PRE_STATUS" = "cancelled" ]; then
  say "job already cancelled by user — skipping (no work, no error)"
  CLIP_REACHED_TERMINAL=1
  exit 0
fi

api_status "status=rendering" "progress=0.02"

say "STEP 1: snapshot"
STATE_JSON=$(spec_get_state || true)
if [ -z "$STATE_JSON" ]; then
  die_failed "spec-server /demo/state unreachable"
fi
SAVED_TICK=$(printf '%s' "$STATE_JSON" | node "$CLIP_HELPERS" state-tick)
SAVED_PAUSED=$(printf '%s' "$STATE_JSON" | node "$CLIP_HELPERS" state-paused)
[ "$SAVED_TICK" = "?" ] && SAVED_TICK=0
say "STEP 1: tick=$SAVED_TICK paused=$SAVED_PAUSED"
api_status "status=rendering" "progress=0.05"

LIVE_CAPTURE_STOPPED=0
if [ -n "${MATCH_ID:-}" ]; then
  say "STEP 1a: stop live capture for $MATCH_ID"
  stop_capture "$MATCH_ID"
  LIVE_CAPTURE_STOPPED=1
fi

# CLIP_BAKE_BRANDING=1 enables the player chip + outro. Default off.
BRANDING_ENABLED="${CLIP_BAKE_BRANDING:-0}"
say "BRANDING enabled=${BRANDING_ENABLED}"

# Player chip overlay — rendered once per job by the Remotion
# composition at motion/src/PlayerChip.tsx, then composited onto each
# captured segment via ffmpeg overlay during the polish pass. Mirrors
# the bottom-left chip on web/components/clips/ClipPlayer.vue.
CHIP_NAME=""
CHIP_AVATAR=""
CHIP_KILLS=0
CHIP_MAP=""
CHIP_ROUND=""
CHIP_MOV=""
if [ "$BRANDING_ENABLED" = "1" ] && [ "${CLIP_DISABLE_CHIP:-0}" != "1" ]; then
  CHIP_NAME="${CLIP_DISPLAY_NAME:-}"
  # "Player NNNN" is the api's fallback when no real name was known.
  # Try GSI for a real in-game name before giving up on the placeholder.
  if { [ -z "$CHIP_NAME" ] || printf '%s' "$CHIP_NAME" | grep -qE '^Player [0-9]+$'; } && [ -n "${CLIP_DISPLAY_TARGET_STEAMID:-}" ]; then
    GSI_NAME=$(printf '%s' "$STATE_JSON" \
      | node "$CLIP_HELPERS" name-for-steamid "$CLIP_DISPLAY_TARGET_STEAMID")
    if [ -n "$GSI_NAME" ]; then CHIP_NAME="$GSI_NAME"; fi
  fi
  CHIP_AVATAR="${CLIP_DISPLAY_AVATAR:-}"
  CHIP_KILLS=$(printf '%s' "${CLIP_DISPLAY_KILLS:-}" \
    | awk '{n=int($1); if (n>0) printf "%d", n; else printf "0"}')
  CHIP_MAP="${CLIP_DISPLAY_MAP:-}"
  CHIP_ROUND="${CLIP_DISPLAY_ROUND:-}"
fi

CHIP_OUT_W="${CLIP_OUTPUT_DIMS%x*}"
CHIP_OUT_H="${CLIP_OUTPUT_DIMS#*x}"
[ -z "$CHIP_OUT_W" ] && CHIP_OUT_W=1920
[ -z "$CHIP_OUT_H" ] && CHIP_OUT_H=1080
CHIP_OUT_FPS="${CLIP_OUTPUT_FPS:-60}"

# Chip is ProRes 4444 because this ffmpeg's libvpx-vp9 silently
# strips alpha on webm; ProRes 4444 is the reliable transparent
# intermediate and encodes faster anyway.
MOTION_DIR="${MOTION_DIR:-/opt/game-streamer/motion}"
if [ -n "$CHIP_NAME" ] && [ ! -d "$MOTION_DIR" ]; then
  say "WARN motion project missing at $MOTION_DIR — skipping chip"
fi
if [ -n "$CHIP_NAME" ] && [ -d "$MOTION_DIR" ]; then
  CHIP_MOV="${CLIP_OUT_DIR:-/tmp/game-streamer/clips}/${CLIP_RENDER_JOB_ID}-chip.mov"
  mkdir -p "$(dirname "$CHIP_MOV")"
  CHIP_PROPS=$(CHIP_NAME="$CHIP_NAME" \
               CHIP_AVATAR="$CHIP_AVATAR" \
               CHIP_KILLS="$CHIP_KILLS" \
               CHIP_MAP="$CHIP_MAP" \
               CHIP_ROUND="$CHIP_ROUND" \
               CHIP_OUT_W="$CHIP_OUT_W" \
               CHIP_OUT_H="$CHIP_OUT_H" \
               CHIP_OUT_FPS="$CHIP_OUT_FPS" \
               node -e 'const r = Number(process.env.CHIP_ROUND);
                        process.stdout.write(JSON.stringify({
                          name: process.env.CHIP_NAME,
                          avatarUrl: process.env.CHIP_AVATAR || null,
                          kills: Number(process.env.CHIP_KILLS) || 0,
                          map: process.env.CHIP_MAP || null,
                          round: Number.isFinite(r) && r >= 0 ? Math.floor(r) : null,
                          width: Number(process.env.CHIP_OUT_W),
                          height: Number(process.env.CHIP_OUT_H),
                          fps: Number(process.env.CHIP_OUT_FPS),
                        }))')
  say "CHIP: rendering for '${CHIP_NAME}'"
  if ! (cd "$MOTION_DIR" && \
        node node_modules/.bin/remotion render \
            src/index.ts PlayerChip "$CHIP_MOV" \
            --codec=prores --prores-profile=4444 \
            --pixel-format=yuva444p10le --image-format=png \
            --log=error \
            --props="$CHIP_PROPS"); then
    say "WARN chip render failed — continuing without chip overlay"
    rm -f "$CHIP_MOV"
    CHIP_MOV=""
  fi
fi

CLIP_OUT_DIR="${CLIP_OUT_DIR:-/tmp/game-streamer/clips}"
mkdir -p "$CLIP_OUT_DIR"
CLIP_OUT_FILE="${CLIP_OUT_DIR}/${CLIP_RENDER_JOB_ID}.mp4"
CLIP_THUMB_FILE="${CLIP_OUT_DIR}/${CLIP_RENDER_JOB_ID}.jpg"
rm -f "$CLIP_OUT_FILE" "$CLIP_THUMB_FILE"

# Per-segment output paths + concat list. We render each segment to
# its own file and let ffmpeg concat-demux glue them — this keeps each
# capture session independent (a stall in one doesn't ruin the rest)
# and isolates the speed-correction ffmpeg pass per segment.
SEG_DIR="${CLIP_OUT_DIR}/${CLIP_RENDER_JOB_ID}.segs"
mkdir -p "$SEG_DIR"
rm -f "$SEG_DIR"/*.mp4 "$SEG_DIR/concat.txt" 2>/dev/null || true
: >"$SEG_DIR/concat.txt"

# Render-phase progress 0..1 (web shows render + upload as separate
# bars; upload is pulse-only since the curl POST has no readback).
# BASE=0.05 covers setup overhead before any segment plays.
PROGRESS_BASE=0.05
PROGRESS_SPAN=0.95
ELAPSED_TICKS_TOTAL=0

for SEG_IDX in $(seq 0 $((SEG_COUNT - 1))); do
  SEG_START=$(printf '%s' "$CLIP_SEGMENTS" \
    | node "$CLIP_HELPERS" seg-start-tick "$SEG_IDX")
  SEG_END=$(printf '%s' "$CLIP_SEGMENTS" \
    | node "$CLIP_HELPERS" seg-end-tick "$SEG_IDX")
  # POV target. accountid = steamid64 - 76561197960265728. The lock
  # is applied AFTER seeking + lead-in so the freshly-seeked target
  # gets overridden — otherwise the clip opens on whoever cs2 was
  # last spectating, producing the wrong POV.
  SEG_POV_ACCOUNTID=$(printf '%s' "$CLIP_SEGMENTS" \
    | node "$CLIP_HELPERS" seg-pov-accountid "$SEG_IDX")
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
  # Hard cap: never let one segment's loop run more than N× expected.
  # The normal exit path is ELAPSED_MS >= WALLCLOCK_MS; this guards
  # against the loop body itself stalling (sleep(1) returning slow,
  # awk math drifting, etc).
  WALLCLOCK_DEADLINE_MS=$((WALLCLOCK_MS * CLIP_SEGMENT_TIMEOUT_FACTOR))
  say "STEP 7: capturing ${SEG_DURATION_MS}ms in ${WALLCLOCK_MS}ms wallclock (cap ${WALLCLOCK_DEADLINE_MS}ms)"

  ELAPSED_MS=0
  LAST_STATE_LOG=0
  WALLCLOCK_START_MS=$(date +%s%3N 2>/dev/null || awk 'BEGIN{srand(); printf "%d", systime()*1000}')
  while [ "$ELAPSED_MS" -lt "$WALLCLOCK_MS" ]; do
    if ! kill -0 "${CLIP_CAPTURE_PID:-0}" 2>/dev/null; then
      die_failed "clip capture died mid-render (segment $SEG_IDX)"
    fi
    NOW_MS=$(date +%s%3N 2>/dev/null || echo $((WALLCLOCK_START_MS + ELAPSED_MS)))
    if [ $((NOW_MS - WALLCLOCK_START_MS)) -gt "$WALLCLOCK_DEADLINE_MS" ]; then
      say "WARN segment $SEG_IDX exceeded ${WALLCLOCK_DEADLINE_MS}ms wallclock cap — stopping capture early"
      break
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

  # Per-segment polish pass — combines slowdown (when CLIP_RENDER_SPEED
  # != 1) and chip overlay (when CHIP_MOV is set) into a single ffmpeg
  # call so we don't re-encode twice. Skipped when neither applies so
  # the speed=1 + no-chip path keeps gstreamer's capture intact.
  if [ "$CLIP_RENDER_SPEED" != "1" ] || [ -n "$CHIP_MOV" ]; then
    HAS_AUDIO=0
    if has_audio_stream "$SEG_FILE"; then HAS_AUDIO=1; fi
    POLISH_FILE="${SEG_FILE}.polish.mp4"

    # Build the video filter graph. We always go through filter_complex
    # so the chip-overlay path can splice in cleanly.
    if [ "$CLIP_RENDER_SPEED" != "1" ]; then
      FC_VIDEO="[0:v]setpts=${CLIP_RENDER_SPEED}*PTS[v0]"
    else
      FC_VIDEO="[0:v]null[v0]"
    fi
    if [ -n "$CHIP_MOV" ]; then
      # shortest=0 + format=auto: keep the underlying segment's
      # duration, blend the chip's alpha properly. The chip mov is
      # only ~3.5s — past its end the [1:v] stream ends and overlay
      # falls through with no chip drawn (eof_action=pass).
      FC_VIDEO="${FC_VIDEO};[v0][1:v]overlay=0:0:eof_action=pass:format=auto[vout]"
      INPUT_ARGS=(-i "$SEG_FILE" -i "$CHIP_MOV")
    else
      FC_VIDEO="${FC_VIDEO};[v0]null[vout]"
      INPUT_ARGS=(-i "$SEG_FILE")
    fi

    AUDIO_ARGS=()
    if [ "$HAS_AUDIO" = "1" ]; then
      if [ "$CLIP_RENDER_SPEED" != "1" ]; then
        case "$CLIP_RENDER_SPEED" in
          2) ATEMPO_FILTER="atempo=0.5" ;;
          3) ATEMPO_FILTER="atempo=0.5,atempo=0.667" ;;
          4) ATEMPO_FILTER="atempo=0.5,atempo=0.5" ;;
          *) ATEMPO_FILTER="atempo=0.5" ;;
        esac
        AUDIO_ARGS=(-map 0:a -af "$ATEMPO_FILTER" -c:a aac -b:a 192k)
      else
        AUDIO_ARGS=(-map 0:a -c:a aac -b:a 192k)
      fi
    else
      AUDIO_ARGS=(-an)
    fi

    if ! ffmpeg -y -hide_banner -loglevel warning \
         "${INPUT_ARGS[@]}" \
         -filter_complex "$FC_VIDEO" \
         -map "[vout]" \
         "${AUDIO_ARGS[@]}" \
         -c:v libx264 -preset veryfast -crf 22 -pix_fmt yuv420p \
         -profile:v high -level 4.2 \
         -movflags +faststart \
         "$POLISH_FILE"; then
      rm -f "$POLISH_FILE"
      die_failed "ffmpeg polish pass failed (segment $SEG_IDX)"
    fi
    mv -f "$POLISH_FILE" "$SEG_FILE"
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

# Outro append. We track whether one was added so the concat below
# knows to skip stream-copy (mismatched PTS between captured segments
# and the Remotion outro pushes the outro ~30s past in stream-copy).
OUTRO_APPENDED=0
if [ "$BRANDING_ENABLED" = "1" ] && [ "${CLIP_DISABLE_OUTRO:-0}" != "1" ]; then
  OUTRO_DIMS="${CLIP_OUTPUT_DIMS:-1920x1080}"
  OUTRO_FPS="${CLIP_OUTPUT_FPS:-60}"
  OUTRO_FILE="${OUTRO_DIR:-/opt/game-streamer/resources/video}/outro_${OUTRO_DIMS}_${OUTRO_FPS}.mp4"
  if [ -f "$OUTRO_FILE" ]; then
    say "OUTRO: appending $OUTRO_FILE"
    printf "file '%s'\n" "$OUTRO_FILE" >>"$SEG_DIR/concat.txt"
    SEG_COUNT=$((SEG_COUNT + 1))
    OUTRO_APPENDED=1
  else
    say "OUTRO: missing $OUTRO_FILE — shipping without outro"
  fi
fi

# Concat — direct cuts between segments. We tried 0.4s fade
# transitions earlier and the result was a longer-than-expected dip
# to black at every join (cs2's seek-loading frames at the head of
# each segment compound with the fade-in, producing 0.5-1s of dead
# air per cut). For a frag montage the harder pace of direct cuts
# reads better and the action stays continuous.
#
# Encoder strategy: try `-c copy` first — every segment is already
# h264/aac (from gst at speed=1, or from the libx264 slowdown pass at
# speed>1), so a stream copy is bit-perfect and finishes near disk-IO
# speed instead of a second full 1080p60 encode. Concat-demuxer copy
# only works when timebase + codec params line up across inputs, and
# nvh264enc vs x264enc + the slowdown pass can produce mismatched
# params on some pods. Re-encode is the fallback for that case.
if [ "$SEG_COUNT" = "1" ]; then
  ONLY_SEG=$(awk -F"'" '/^file/{print $2}' "$SEG_DIR/concat.txt" | head -1)
  mv -f "$ONLY_SEG" "$CLIP_OUT_FILE"
elif [ "$OUTRO_APPENDED" = "1" ]; then
  # concat filter (not demuxer) — regenerates PTS cleanly. The
  # captured segments carry trailing PTS that pushes the outro ~30s
  # past with -c copy. Filter-graph concat is the reliable splice
  # across heterogeneous sources.
  say "STEP 9: ffmpeg concat ${SEG_COUNT} segments (with outro, filter-graph)"
  CONCAT_INPUTS=()
  while IFS= read -r line; do
    f=$(printf '%s' "$line" | awk -F"'" '/^file/{print $2}')
    [ -n "$f" ] && CONCAT_INPUTS+=("-i" "$f")
  done <"$SEG_DIR/concat.txt"
  N=${#SEG_COUNT}
  FC=""
  for i in $(seq 0 $((SEG_COUNT - 1))); do
    FC+="[${i}:v:0][${i}:a:0]"
  done
  FC+="concat=n=${SEG_COUNT}:v=1:a=1[v][a]"
  if ! ffmpeg -y -hide_banner -loglevel warning \
       "${CONCAT_INPUTS[@]}" \
       -filter_complex "$FC" \
       -map "[v]" -map "[a]" \
       -c:v libx264 -preset veryfast -crf 22 -pix_fmt yuv420p \
       -profile:v high -level 4.2 \
       -c:a aac -b:a 192k -ar 48000 -ac 2 \
       -movflags +faststart \
       "$CLIP_OUT_FILE"; then
    die_failed "ffmpeg concat (filter-graph) failed"
  fi
else
  say "STEP 9: ffmpeg concat ${SEG_COUNT} segments (direct cuts)"
  if ffmpeg -y -hide_banner -loglevel warning \
       -f concat -safe 0 -i "$SEG_DIR/concat.txt" \
       -c copy \
       -movflags +faststart \
       "$CLIP_OUT_FILE" 2>/dev/null; then
    say "  concat: stream-copy succeeded"
  else
    rm -f "$CLIP_OUT_FILE"
    say "  concat: stream-copy refused — re-encoding"
    if ! ffmpeg -y -hide_banner -loglevel warning \
         -f concat -safe 0 -i "$SEG_DIR/concat.txt" \
         -c:v libx264 -preset veryfast -crf 22 \
         -c:a aac -b:a 192k \
         -movflags +faststart \
         "$CLIP_OUT_FILE"; then
      die_failed "ffmpeg concat failed"
    fi
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

THUMB_SEEK_SECS=3
THUMB_DURATION_SECS=$(awk -v ms="$REAL_DURATION_MS" 'BEGIN{printf "%.3f", ms/1000}')
if awk -v d="$THUMB_DURATION_SECS" -v t="$THUMB_SEEK_SECS" 'BEGIN{exit !(d <= t)}'; then
  THUMB_SEEK_SECS=$(awk -v d="$THUMB_DURATION_SECS" 'BEGIN{printf "%.3f", d/2}')
fi
if ffmpeg -y -hide_banner -loglevel warning \
     -ss "$THUMB_SEEK_SECS" -i "$CLIP_OUT_FILE" -frames:v 1 -q:v 3 \
     "$CLIP_THUMB_FILE" 2>/dev/null \
   && [ -s "$CLIP_THUMB_FILE" ]; then
  THUMB_URL="${STATUS_API_BASE}/clip-renders/${CLIP_RENDER_JOB_ID}/thumbnail"
  say "POST $THUMB_URL"
  if ! curl --fail --silent --show-error \
         --max-time 60 \
         --header "x-origin-auth: ${CLIP_RENDER_JOB_ID}:${CLIP_RENDER_TOKEN}" \
         --header "content-type: image/jpeg" \
         --data-binary "@${CLIP_THUMB_FILE}" \
         --output /dev/null \
         "$THUMB_URL"; then
    say "WARN thumbnail upload failed — continuing without thumbnail"
  fi
else
  say "WARN ffmpeg thumbnail extraction failed — continuing without thumbnail"
fi
rm -f "$CLIP_THUMB_FILE"

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
CLIP_REACHED_TERMINAL=1
rm -f "$CLIP_OUT_FILE"
say "done"
