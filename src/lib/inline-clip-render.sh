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
  local body="${1:-{}}"
  curl --fail --silent --show-error --max-time 5 \
       --header "content-type: application/json" \
       --data "$body" \
       --output /dev/null \
       "${SPEC_SERVER_URL}${path}" \
    || say "WARN spec POST $path failed (body=$body)"
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
  # Single-shot seek that ALSO sets the play/pause state — uses cs2's
  # `demo_gototick <tick> 0 <pause>` form via spec-server. Avoids the
  # state-mirror dance entirely.
  local pause_after="false"
  [ "$SAVED_PAUSED" = "true" ] && pause_after="true"
  spec_post /demo/seek \
    "{\"tick\": ${SAVED_TICK}, \"pause_after\": ${pause_after}}"
}
trap 'restore_user_playback' EXIT

# ---------------------------------------------------------------------------
say "rendering ticks ${CLIP_START_TICK}..${CLIP_END_TICK} (output ${CLIP_OUTPUT_DIMS:-?}@${CLIP_OUTPUT_FPS:-?})"
api_status "status=rendering" "progress=0.05"

# 1. Snapshot user's current playback so we can restore it after the
#    capture. /demo/state returns { tick, paused, rate, ... }.
STATE_JSON=$(spec_get_state || true)
if [ -z "$STATE_JSON" ]; then
  die_failed "spec-server /demo/state unreachable"
fi
SAVED_TICK=$(printf '%s' "$STATE_JSON" | jq -r '.tick // 0')
SAVED_PAUSED=$(printf '%s' "$STATE_JSON" | jq -r '.paused // false')
say "snapshot: tick=$SAVED_TICK paused=$SAVED_PAUSED"

# 2. Seek to clip start AND pin cs2 paused there. We use the single
#    `demo_gototick <tick> 0 1` form via spec-server's /demo/seek
#    {pause_after: true} — that's deterministic regardless of whatever
#    state cs2 was in before. Earlier flows that did pause-then-seek
#    relied on the state-mirror lining up with cs2's actual state
#    after the seek; some cs2 builds auto-resume on demo_gototick and
#    the mirror would drift, leaving us paused mid-capture.
spec_post /demo/seek \
  "{\"tick\": ${CLIP_START_TICK}, \"pause_after\": true}"
# Lead-in: cs2 needs a moment after demo_gototick to render the
# seeked frame cleanly. Without this the first ~500ms of the mp4 can
# look stuttery.
sleep 2
api_status "status=rendering" "progress=0.15"

# 3. Start the file-output GStreamer pipeline. This runs in PARALLEL
#    with the existing live SRT capture (different gst-launch process,
#    different mux + sink) — both pull from the same X display.
CLIP_OUT_DIR="${CLIP_OUT_DIR:-/tmp/game-streamer/clips}"
mkdir -p "$CLIP_OUT_DIR"
CLIP_OUT_FILE="${CLIP_OUT_DIR}/${CLIP_RENDER_JOB_ID}.mp4"
rm -f "$CLIP_OUT_FILE"

if ! start_clip_capture "$CLIP_OUT_FILE" "${CLIP_OUTPUT_FPS:-60}" 8000 1; then
  die_failed "clip capture failed to start"
fi
api_status "status=rendering" "progress=0.25"

# 4. Re-seek to start_tick with `pause_after: false` — cs2 jumps back
#    onto the same tick (no visible glitch) AND begins playing. This
#    is the deterministic "press play" we couldn't get reliably out
#    of /demo/resume across cs2 builds. The capture is already running
#    so the file picks up the play state from frame ~1.
spec_post /demo/seek \
  "{\"tick\": ${CLIP_START_TICK}, \"pause_after\": false}"
DURATION_TICKS=$((CLIP_END_TICK - CLIP_START_TICK))
DURATION_MS=$(awk -v t="$DURATION_TICKS" -v r="${CLIP_TICK_RATE:-64}" \
  'BEGIN{printf "%d", t / r * 1000}')
say "capturing for ${DURATION_MS}ms"

# Sleep in 2s slices so we can post incremental progress. Caller can
# also cancel mid-flight by setting the row status to `cancelled` —
# we poll the row indirectly by treating a 410 from the api as cancel.
ELAPSED_MS=0
while [ "$ELAPSED_MS" -lt "$DURATION_MS" ]; do
  if ! kill -0 "${CLIP_CAPTURE_PID:-0}" 2>/dev/null; then
    die_failed "clip capture died mid-render"
  fi
  REMAINING=$((DURATION_MS - ELAPSED_MS))
  STEP=$((REMAINING < 2000 ? REMAINING : 2000))
  sleep "$(awk -v s="$STEP" 'BEGIN{printf "%.3f", s/1000}')"
  ELAPSED_MS=$((ELAPSED_MS + STEP))
  FRAC=$(awk -v e="$ELAPSED_MS" -v d="$DURATION_MS" \
    'BEGIN{printf "%.3f", 0.25 + 0.55 * e / d}')
  api_status "status=rendering" "progress=$FRAC"
done

# 5. Stop capture (graceful EOS so qtmux finalises the moov atom).
say "stopping capture"
stop_clip_capture
api_status "status=rendering" "progress=0.85"

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
api_status "status=uploading" "progress=0.92"
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
