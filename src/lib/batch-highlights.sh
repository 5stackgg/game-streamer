# shellcheck shell=bash
# batch-highlights.sh — drains a queue of clip_render_jobs against a
# single, already-running cs2 demo session.
#
# Sourced by run-demo.sh when CLIP_BATCH_MODE=1. The contract:
#
#   IN (env, set by api dispatchBatchHighlights):
#     CLIP_BATCH_JOBS  - JSON array of {job_id, token, spec}
#     STATUS_API_BASE  - api base url (in-cluster, e.g. http://api:5585)
#     SPEC_SERVER_URL  - already running on this pod (default 1350)
#     DEMO_TICK_RATE   - parsed tickrate (defaults to 64)
#
#   FLOW:
#     For each job in CLIP_BATCH_JOBS:
#       - Translate spec.segments + spec.output into the env vars
#         inline-clip-render.sh expects.
#       - Invoke inline-clip-render.sh.
#       - The render script handles status reporting, segment
#         capture, fade trim, and upload itself.
#     After the loop completes (success or per-job failures), exit
#     so the k8s Job ttlSecondsAfterFinished reaps the pod.
#
# Per-job failures DO NOT halt the batch — one player's render
# crashing shouldn't lose the rest of the team's highlights. The
# render script already POSTs status=error to the api on failure,
# so the failed jobs are visible in /manage-clips for an admin to
# retry or clean up.

# Run a single job's render. Translates a JSON job blob into the
# env contract inline-clip-render.sh expects.
batch_render_one_job() {
  local job_json="$1"

  local job_id token segments output_dims output_fps render_speed
  job_id=$(printf '%s' "$job_json" | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("job_id",""))')
  token=$(printf '%s' "$job_json" | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("token",""))')
  segments=$(printf '%s' "$job_json" | python3 -c \
    'import json,sys; print(json.dumps(json.load(sys.stdin).get("spec",{}).get("segments",[])))')
  output_dims=$(printf '%s' "$job_json" | python3 -c \
    "import json,sys
spec = json.load(sys.stdin).get('spec',{}).get('output',{}) or {}
res = spec.get('resolution', '1080p')
print('1280x720' if res == '720p' else '1920x1080')")
  output_fps=$(printf '%s' "$job_json" | python3 -c \
    'import json,sys
spec = json.load(sys.stdin).get("spec",{}).get("output",{}) or {}
print(int(spec.get("fps", 60)))')
  render_speed="${CLIP_RENDER_SPEED:-1}"

  if [ -z "$job_id" ] || [ -z "$token" ]; then
    say "  skipping malformed job blob: $job_json"
    return 0
  fi

  say "----- batch render: $job_id"

  # Invoke the existing per-job render script with the right env.
  # Run it in a subshell so its `trap '...' EXIT` handler doesn't
  # affect this loop, and so its env vars don't leak into the next
  # iteration. We do NOT pass MATCH_ID (no live capture to stop /
  # restart in batch mode — there isn't one to begin with).
  (
    export CLIP_RENDER_JOB_ID="$job_id"
    export CLIP_RENDER_TOKEN="$token"
    export CLIP_SEGMENTS="$segments"
    export CLIP_OUTPUT_DIMS="$output_dims"
    export CLIP_OUTPUT_FPS="$output_fps"
    export CLIP_TICK_RATE="${DEMO_TICK_RATE:-64}"
    export SPEC_SERVER_URL="${SPEC_SERVER_URL:-http://127.0.0.1:1350}"
    export CLIP_RENDER_SPEED="$render_speed"
    unset MATCH_ID  # batch pod doesn't publish a match capture
    bash "$LIB_DIR/inline-clip-render.sh"
  ) || say "  job $job_id failed (continuing — others in batch unaffected)"

  say "----- batch render: $job_id done"
}

# Drain CLIP_BATCH_JOBS sequentially.
process_batch_jobs() {
  if [ -z "${CLIP_BATCH_JOBS:-}" ]; then
    say "no CLIP_BATCH_JOBS env — nothing to render, exiting"
    return 0
  fi

  local count
  count=$(printf '%s' "$CLIP_BATCH_JOBS" | python3 -c \
    'import json,sys; print(len(json.load(sys.stdin)))')
  say "===================================================="
  say "batch-highlights: ${count} job(s) queued — starting"
  say "===================================================="

  # Wait for the demo to actually be PLAYING before kicking off the
  # first render — the initial seek inside inline-clip-render.sh
  # silently lands on tick 0 if cs2 hasn't loaded the demo yet, and
  # we'd capture 8s of black. /demo/state's `gsi` field becomes
  # non-null once GSI fires, which is the same signal the demo
  # session's status='playing' transition uses.
  local i ready=0
  for i in $(seq 1 60); do
    local s
    s=$(curl --fail --silent --show-error --max-time 5 \
            "${SPEC_SERVER_URL:-http://127.0.0.1:1350}/demo/state" \
        || true)
    if [ -n "$s" ]; then
      local has_gsi
      has_gsi=$(printf '%s' "$s" | python3 -c \
        'import json,sys
try:
    d=json.load(sys.stdin)
    print("1" if d.get("gsi") else "0")
except Exception:
    print("0")')
      if [ "$has_gsi" = "1" ]; then
        ready=1
        break
      fi
    fi
    sleep 1
  done
  if [ "$ready" != "1" ]; then
    say "WARN GSI never fired after 60s — proceeding anyway, first render may capture loading frames"
  fi

  # GSI fires on the first state update from cs2 (demo loaded), but
  # the spec-server's reportDemoPlayingOnce queues the demoui hide on
  # a 3s setTimeout after that first GSI tick — same logic the demo
  # session pod uses to wait for the panorama panel to render before
  # toggling it off. Without this sleep, the first render in the batch
  # captures cs2 with the demoui panel still on screen. 4s = 3s for
  # the setTimeout + 1s cushion for the toggle to actually take
  # effect on the GPU compositor before ximagesrc grabs frames.
  say "demo loaded — waiting 4s for demoui hide + render-ready"
  sleep 4

  local idx
  for idx in $(seq 0 $((count - 1))); do
    local job_json
    job_json=$(printf '%s' "$CLIP_BATCH_JOBS" | python3 -c \
      "import json,sys; print(json.dumps(json.load(sys.stdin)[$idx]))")
    batch_render_one_job "$job_json"
  done

  say "===================================================="
  say "batch-highlights: drained ${count} job(s) — exiting"
  say "===================================================="
}
