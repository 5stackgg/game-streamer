#!/usr/bin/env bash
# inline-clip-render.sh — render a single user-requested clip from
# WITHIN the running demo-watch pod. Spawned as a detached child by the
# spec-server when the api POSTs to /demo/render-clip.
#
# Why inline (not a fresh k8s pod):
#   The watching pod already has Steam logged in, cs2 running with the
#   demo loaded, GPU + Xorg up, mediamtx publishing to WHEP, and the
#   .dem on disk. Spawning a second pod throws all of that away —
#   60-90s of setup-steam, a full demo re-download, and a second GPU
#   slot per render. Inline render reuses everything.
#
# Trade-off: the user's playback gets briefly disrupted while we
# pause/seek-to-start/capture/seek-back. They explicitly clicked
# "Create clip" so a few seconds of disruption is expected UX.
#
# Required env (set by spec-server.mjs):
#   CLIP_RENDER_JOB_ID    uuid of the clip_render_jobs row
#   CLIP_RENDER_TOKEN     session token (paired with JOB_ID for x-origin-auth)
#   STATUS_API_BASE       api root (e.g. http://api:5585) for /clip-renders/:id/{status,upload}
#   CLIP_START_TICK       demo tick to start capturing from
#   CLIP_END_TICK         demo tick to stop capturing at
#   CLIP_OUTPUT_DIMS      "1280x720" | "1920x1080" (we don't resize cs2 — informational only)
#   CLIP_OUTPUT_FPS       30 | 60
#   CLIP_TICK_RATE        from spec-server's tracked demoState (defaults 64)
#   SPEC_SERVER_URL       http://127.0.0.1:1350 — the same daemon that spawned us
#
# Status reported back to the api: rendering → uploading → done | error.

set -uo pipefail
SCRIPT_TAG=inline-clip

# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/clip-capture.sh"

require_env CLIP_RENDER_JOB_ID CLIP_RENDER_TOKEN STATUS_API_BASE \
            CLIP_START_TICK CLIP_END_TICK SPEC_SERVER_URL

# Run-id-tagged log lines so multiple concurrent (queued) renders are
# distinguishable in the pod log.
LOG_PREFIX="[clip ${CLIP_RENDER_JOB_ID:0:8}]"
say() { printf '%s %s\n' "$LOG_PREFIX" "$*" >&2; }

# ---------------------------------------------------------------------------
# Helpers — the spec-server's /demo/* routes use plain JSON; curl piped
# through jq for parsing. The api's /clip-renders/:id/* routes auth
# with x-origin-auth: <job_id>:<token>.

api_status() {
  # report_status_for_clip <key=val> [...]
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
  # Pipe the body via stdin instead of `--data "$body"`. curl's
  # `--data` was returning 400 invalid-json in earlier runs — likely
  # because shell quoting around braces / spaces was leaking into
  # what curl actually sent. `--data-binary @-` reads stdin verbatim
  # so what we hand it is exactly what hits the wire.
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

# Always try to leave the user's playback the way we found it, even on
# unexpected exits. This trap fires on script errors AND on stop_clip_capture
# success — we restore from $SAVED_TICK / $SAVED_PAUSED captured below.
SAVED_TICK=""
SAVED_PAUSED=""
restore_user_playback() {
  if [ -z "$SAVED_TICK" ]; then return 0; fi
  say "RESTORE: pausing + seeking to saved tick=$SAVED_TICK paused=$SAVED_PAUSED"
  spec_post /demo/pause '{"force": true}'
  spec_post /demo/seek "{\"tick\": ${SAVED_TICK}}"
  if [ "$SAVED_PAUSED" != "true" ]; then
    spec_post /demo/toggle '{}'
    say "RESTORE: toggled play (user was playing before)"
  fi
  log_state "after RESTORE"
}
trap 'restore_user_playback' EXIT

# Helper: dump cs2's state via spec-server /demo/state. Logs tick +
# paused so we can SEE in the pod log whether each step actually moved
# cs2 to the expected state.
log_state() {
  local label="$1"
  local s tick paused
  s=$(spec_get_state || true)
  if [ -z "$s" ]; then
    say "STATE [$label]: <unreachable>"
    return
  fi
  tick=$(printf '%s' "$s" | jq -r '.tick // "?"')
  paused=$(printf '%s' "$s" | jq -r '.paused // "?"')
  say "STATE [$label]: tick=$tick paused=$paused"
}

# ---------------------------------------------------------------------------
# Progress mapping — render fills 0% → 50%, upload fills 50% → 100%.
# That keeps the bar visually balanced even though render takes much
# longer than upload in wallclock; the bar slows during render and
# accelerates during upload, but each phase has a predictable share.
say "============================================================"
say "rendering ticks ${CLIP_START_TICK}..${CLIP_END_TICK} (output ${CLIP_OUTPUT_DIMS:-?}@${CLIP_OUTPUT_FPS:-?})"
say "============================================================"
api_status "status=rendering" "progress=0.02"

# 1. Snapshot user's current playback so we can restore it after the
#    capture. /demo/state returns { tick, paused, rate, ... }.
say "STEP 1: snapshot user playback"
STATE_JSON=$(spec_get_state || true)
if [ -z "$STATE_JSON" ]; then
  die_failed "spec-server /demo/state unreachable"
fi
SAVED_TICK=$(printf '%s' "$STATE_JSON" | jq -r '.tick // 0')
SAVED_PAUSED=$(printf '%s' "$STATE_JSON" | jq -r '.paused // false')
say "STEP 1: snapshot tick=$SAVED_TICK paused=$SAVED_PAUSED"
api_status "status=rendering" "progress=0.05"

# 2. FORCE-pause via the explicit cs2 `demo_pause` console command
#    (idempotent — no-op if cs2 is already paused). Now the state is
#    KNOWN paused, regardless of whatever the spec-server mirror said.
say "STEP 2: force-pause cs2 via demo_pause console command"
spec_post /demo/pause '{"force": true}'
log_state "after force-pause"

# 3. Seek to start_tick. cs2 stays paused (we just force-paused) and
#    frame-steps to the exact tick. We do NOT pass pause_after — that
#    arg is build-flaky on cs2 and the user's build silently ignores
#    it. We rely on the explicit pause/toggle sequence instead.
say "STEP 3: seek to start_tick=$CLIP_START_TICK"
spec_post /demo/seek "{\"tick\": ${CLIP_START_TICK}}"
api_status "status=rendering" "progress=0.06"

# 4. Lead-in so cs2 has time to render the seeked frame cleanly
#    before we start capturing. Otherwise the first ~500ms of mp4 can
#    look stuttery. Force-pause AGAIN after the lead-in in case cs2's
#    seek ended up auto-resuming behind our back (some builds do this).
say "STEP 4: lead-in 2s, then re-confirm paused state"
sleep 2
spec_post /demo/pause '{"force": true}'
log_state "after lead-in + re-pause"
api_status "status=rendering" "progress=0.08"

# 5. Start the file-output GStreamer pipeline. Captures the same X
#    display the user is watching, into a local mp4 (qtmux faststart).
say "STEP 5: start GStreamer file capture"
CLIP_OUT_DIR="${CLIP_OUT_DIR:-/tmp/game-streamer/clips}"
mkdir -p "$CLIP_OUT_DIR"
CLIP_OUT_FILE="${CLIP_OUT_DIR}/${CLIP_RENDER_JOB_ID}.mp4"
rm -f "$CLIP_OUT_FILE"

if ! start_clip_capture "$CLIP_OUT_FILE" "${CLIP_OUTPUT_FPS:-60}" 8000 1; then
  die_failed "clip capture failed to start"
fi
say "STEP 5: capture pid=${CLIP_CAPTURE_PID:-?}"
api_status "status=rendering" "progress=0.10"

# 6. PRESS PLAY via the F-key toggle. We're guaranteed paused (step
#    2/4 force-paused via demo_pause console). The Pause F-key is
#    bound to demo_togglepause in autoexec — sending it once flips us
#    from paused → playing. This is the SAME mechanism the user's
#    manual "play" button uses, which we know works reliably.
#
#    Why not the seek-with-pause-flag? The third arg to
#    `demo_gototick` ("pause") is silently ignored on the user's cs2
#    build. The toggle key is the only deterministic resume primitive.
say "STEP 6: PRESS PLAY (send Pause F-key via /demo/toggle)"
spec_post /demo/toggle '{}'
log_state "after toggle (should be paused=false)"

DURATION_TICKS=$((CLIP_END_TICK - CLIP_START_TICK))
DURATION_MS=$(awk -v t="$DURATION_TICKS" -v r="${CLIP_TICK_RATE:-64}" \
  'BEGIN{printf "%d", t / r * 1000}')
say "STEP 7: capturing for ${DURATION_MS}ms"

# Sleep in 2s slices so we can post incremental progress and log
# cs2's actual state every few seconds. If cs2 silently re-pauses
# mid-capture (which is the failure mode we keep hitting) the log
# will show paused=true and we know to retry the toggle.
ELAPSED_MS=0
LAST_STATE_LOG=0
while [ "$ELAPSED_MS" -lt "$DURATION_MS" ]; do
  if ! kill -0 "${CLIP_CAPTURE_PID:-0}" 2>/dev/null; then
    die_failed "clip capture died mid-render"
  fi
  # Every ~5s during capture, log cs2's current tick + paused so we
  # can verify in the pod log that it's actually advancing.
  if [ $((ELAPSED_MS - LAST_STATE_LOG)) -ge 5000 ]; then
    log_state "capture +${ELAPSED_MS}ms"
    LAST_STATE_LOG=$ELAPSED_MS
  fi
  REMAINING=$((DURATION_MS - ELAPSED_MS))
  STEP=$((REMAINING < 2000 ? REMAINING : 2000))
  sleep "$(awk -v s="$STEP" 'BEGIN{printf "%.3f", s/1000}')"
  ELAPSED_MS=$((ELAPSED_MS + STEP))
  # Capture loop fills 0.10 → 0.50 — owns the second half of the
  # rendering phase. Upload then fills 0.50 → 1.0.
  FRAC=$(awk -v e="$ELAPSED_MS" -v d="$DURATION_MS" \
    'BEGIN{printf "%.3f", 0.10 + 0.40 * e / d}')
  api_status "status=rendering" "progress=$FRAC"
done

# Stop capture (graceful EOS so qtmux finalises the moov atom).
say "STEP 8: stop capture"
log_state "before stop"
stop_clip_capture
api_status "status=rendering" "progress=0.50"

# 6. Restore user's playback BEFORE the upload — they've been waiting
#    long enough; let them resume watching while the upload runs.
restore_user_playback
# Clear the trap-driven restore: we already did it.
SAVED_TICK=""
trap - EXIT

# 7. Sanity-check the file + grab real duration via ffprobe.
[ -s "$CLIP_OUT_FILE" ] || die_failed "clip output is empty"
CLIP_BYTES=$(stat -c '%s' "$CLIP_OUT_FILE" 2>/dev/null \
  || stat -f '%z' "$CLIP_OUT_FILE")
say "rendered $CLIP_OUT_FILE ($CLIP_BYTES bytes)"
REAL_DURATION_MS=$(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 "$CLIP_OUT_FILE" 2>/dev/null \
  | awk '{printf "%d", $1 * 1000}')
[ -z "$REAL_DURATION_MS" ] && REAL_DURATION_MS="$DURATION_MS"

# 8. Upload to the api. Streams the body straight off disk — the api
#    pipes it into S3 without buffering.
# Upload phase owns 50% → 100%. curl doesn't surface mid-upload
# progress without piping through pv, so the bar pauses at 50% during
# the upload and jumps to 100% on success — most clips upload in <5s
# so this reads cleanly.
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
  die_failed "clip upload failed (see /tmp/clip-upload-response.json)"
fi

# api auto-promotes the row to status=done in finalizeClipUpload, so we
# don't strictly need the next status post — but it's idempotent and
# the pod log line "status=done" is useful when debugging from the pod
# side instead of the api.
api_status "status=done" "progress=1.0"
rm -f "$CLIP_OUT_FILE"
say "done"
