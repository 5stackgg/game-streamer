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

# Resolve a player's GSI-reported name for a target steamid. cs2 GSI
# carries the actual in-game player name; the api couldn't get this
# at enqueue time (only steam_id from the parsed kills jsonb), so
# titles defaulted to "Player NNNN". Now that the pod has cs2 + GSI
# loaded, we look up the real name and tell the api to patch the
# title before this render starts.
patch_title_from_gsi() {
  local job_id="$1"
  local token="$2"
  local target_sid="$3"
  local current_title="$4"

  if [ -z "$target_sid" ] || [ -z "$current_title" ]; then
    return 0
  fi

  local state
  state=$(curl --fail --silent --show-error --max-time 5 \
       "${SPEC_SERVER_URL:-http://127.0.0.1:1350}/demo/state" \
    || true)
  if [ -z "$state" ]; then
    return 0
  fi
  local resolved
  resolved=$(printf '%s' "$state" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
    target = '$target_sid'
    for s in d.get('gsi', {}).get('spec_slots', []):
        if s.get('steam_id') == target and s.get('name'):
            print(s['name'])
            sys.exit(0)
except Exception:
    pass
print('')")
  if [ -z "$resolved" ]; then
    return 0
  fi

  # Replace the "Player NNNN" prefix in the title with the resolved
  # name. Other suffix patterns (em-dash + " Best Round (XK)") stay.
  local new_title
  new_title=$(printf '%s' "$current_title" | python3 -c "
import sys, re
title = sys.stdin.read()
new_name = '$resolved'
out = re.sub(r'^Player [A-Za-z0-9_-]+', new_name, title)
print(out)")
  if [ -z "$new_title" ] || [ "$new_title" = "$current_title" ]; then
    return 0
  fi

  curl --fail --silent --show-error --max-time 5 \
       --header "x-origin-auth: ${job_id}:${token}" \
       --header "content-type: application/json" \
       --data "$(printf '{"title": "%s"}' "${new_title//\"/\\\"}")" \
       --output /dev/null \
       "${STATUS_API_BASE}/clip-renders/${job_id}/title" \
    || say "  WARN title patch failed for $job_id (continuing — render still proceeds)"
}

# Run a single job's render. Translates a JSON job blob into the
# env contract inline-clip-render.sh expects.
batch_render_one_job() {
  local job_json="$1"

  local job_id token segments output_dims output_fps render_speed
  local target_sid current_title
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
  # First segment's pov_steam_id is the player this clip is "about".
  # All preset segments share the same pov, so segment[0] is fine.
  target_sid=$(printf '%s' "$job_json" | python3 -c \
    'import json,sys
try:
    seg = (json.load(sys.stdin).get("spec",{}).get("segments",[]) or [{}])[0]
    print(seg.get("pov_steam_id","") or "")
except Exception:
    print("")')
  current_title=$(printf '%s' "$job_json" | python3 -c \
    'import json,sys
try:
    print(json.load(sys.stdin).get("spec",{}).get("title","") or "")
except Exception:
    print("")')
  render_speed="${CLIP_RENDER_SPEED:-1}"

  if [ -z "$job_id" ] || [ -z "$token" ]; then
    say "  skipping malformed job blob: $job_json"
    return 0
  fi

  say "----- batch render: $job_id"

  # Resolve player name from cs2 GSI (now that the demo is loaded)
  # and patch the title via api so finalizeClipUpload picks it up.
  patch_title_from_gsi "$job_id" "$token" "$target_sid" "$current_title"

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

  # Wait for cs2 to be in a fully render-ready state. Two stages:
  #
  #   (a) GSI has fired at least once — confirms the demo is actually
  #       loaded. Without this, the first render's seek lands on
  #       tick 0 of an unloaded demo and captures black.
  #   (b) `demoui_hidden` is true — confirms spec-server has
  #       delivered the demoui-toggle keystroke (post-GSI 3s
  #       setTimeout). Without this, the first render captures the
  #       demo panorama panel still on screen.
  #
  # Same readiness contract the demo session pod uses internally:
  # the api's status='playing' transition fires from spec-server's
  # reportDemoPlayingOnce which schedules the demoui hide and the
  # `demoui_hidden` flag is what tells us "actually toggled".
  say "waiting for demo-ready signal (GSI + demoui_hidden)"
  local i demo_ready=0
  for i in $(seq 1 90); do
    local s
    s=$(curl --fail --silent --show-error --max-time 5 \
            "${SPEC_SERVER_URL:-http://127.0.0.1:1350}/demo/state" \
        || true)
    if [ -n "$s" ]; then
      local ready
      ready=$(printf '%s' "$s" | python3 -c \
        'import json,sys
try:
    d=json.load(sys.stdin)
    gsi=d.get("gsi") or {}
    print("1" if gsi and gsi.get("demoui_hidden") else "0")
except Exception:
    print("0")')
      if [ "$ready" = "1" ]; then
        demo_ready=1
        break
      fi
    fi
    sleep 1
  done
  if [ "$demo_ready" != "1" ]; then
    say "WARN demo-ready signal never arrived after 90s — proceeding; first render may capture loading frames"
  else
    say "demo ready — first render will capture clean frames"
  fi

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
