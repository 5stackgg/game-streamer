# shellcheck shell=bash
# Drain CLIP_BATCH_JOBS against the running cs2 demo session. Sourced
# by run-demo.sh when CLIP_BATCH_MODE=1. Per-job failures don't halt
# the batch — the render script POSTs status=error itself.

# JSON parsing flows through node so values can't break the shell.
CLIP_HELPERS="$LIB_DIR/clip-helpers.mjs"

# Patch the api job title with the GSI-reported player name. The api
# only had steam_id at enqueue, so titles default to "Player NNNN".
patch_title_from_gsi() {
  local job_id="$1" token="$2" target_sid="$3" current_title="$4"
  [ -z "$target_sid" ] && return 0
  [ -z "$current_title" ] && return 0

  local state
  state=$(curl --fail --silent --show-error --max-time 5 \
       "${SPEC_SERVER_URL:-http://127.0.0.1:1350}/demo/state" \
    || true)
  [ -z "$state" ] && return 0

  local resolved
  resolved=$(printf '%s' "$state" \
    | node "$CLIP_HELPERS" name-for-steamid "$target_sid")
  [ -z "$resolved" ] && return 0

  local new_title
  new_title=$(printf '%s' "$current_title" \
    | node "$CLIP_HELPERS" patch-player-name "$resolved")
  [ -z "$new_title" ] && return 0
  [ "$new_title" = "$current_title" ] && return 0

  curl --fail --silent --show-error --max-time 5 \
       --header "x-origin-auth: ${job_id}:${token}" \
       --header "content-type: application/json" \
       --data "$(printf '{"title": "%s"}' "${new_title//\"/\\\"}")" \
       --output /dev/null \
       "${STATUS_API_BASE}/clip-renders/${job_id}/title" \
    || say "  WARN title patch failed for $job_id"
}

batch_render_one_job() {
  local job_json="$1"

  local job_id token segments output_dims output_fps render_speed
  local target_sid current_title target_name kills_count team_name map_name round
  job_id=$(printf       '%s' "$job_json" | node "$CLIP_HELPERS" job-id)
  token=$(printf        '%s' "$job_json" | node "$CLIP_HELPERS" job-token)
  segments=$(printf     '%s' "$job_json" | node "$CLIP_HELPERS" job-segments)
  output_dims=$(printf  '%s' "$job_json" | node "$CLIP_HELPERS" job-output-dims)
  output_fps=$(printf   '%s' "$job_json" | node "$CLIP_HELPERS" job-output-fps)
  # All preset segments share the same pov, so segment[0] is fine.
  target_sid=$(printf   '%s' "$job_json" | node "$CLIP_HELPERS" job-first-pov-steamid)
  current_title=$(printf '%s' "$job_json" | node "$CLIP_HELPERS" job-title)
  target_name=$(printf  '%s' "$job_json" | node "$CLIP_HELPERS" job-target-name)
  kills_count=$(printf  '%s' "$job_json" | node "$CLIP_HELPERS" job-kills-count)
  team_name=$(printf    '%s' "$job_json" | node "$CLIP_HELPERS" job-team-name)
  map_name=$(printf     '%s' "$job_json" | node "$CLIP_HELPERS" job-map-name)
  round=$(printf        '%s' "$job_json" | node "$CLIP_HELPERS" job-round)
  render_speed="${CLIP_RENDER_SPEED:-1}"

  if [ -z "$job_id" ] || [ -z "$token" ]; then
    say "  skipping malformed job blob"
    return 0
  fi

  say "batch render: $job_id"
  patch_title_from_gsi "$job_id" "$token" "$target_sid" "$current_title"

  # Subshell so the render script's trap + env don't leak. We do NOT
  # pass MATCH_ID — batch pods don't publish a match capture.
  (
    export CLIP_RENDER_JOB_ID="$job_id"
    export CLIP_RENDER_TOKEN="$token"
    export CLIP_SEGMENTS="$segments"
    export CLIP_OUTPUT_DIMS="$output_dims"
    export CLIP_OUTPUT_FPS="$output_fps"
    export CLIP_TICK_RATE="${DEMO_TICK_RATE:-64}"
    export SPEC_SERVER_URL="${SPEC_SERVER_URL:-http://127.0.0.1:1350}"
    export CLIP_RENDER_SPEED="$render_speed"
    # Chip overlay inputs — name comes from the api job spec when
    # set, falls back to GSI-resolved name inside inline-clip-render.
    # Everything else is optional; the chip omits missing pieces.
    export CLIP_DISPLAY_NAME="$target_name"
    export CLIP_DISPLAY_TARGET_STEAMID="$target_sid"
    export CLIP_DISPLAY_KILLS="$kills_count"
    export CLIP_DISPLAY_TEAM="$team_name"
    export CLIP_DISPLAY_MAP="$map_name"
    export CLIP_DISPLAY_ROUND="$round"
    unset MATCH_ID
    bash "$LIB_DIR/inline-clip-render.sh"
  ) || say "  job $job_id failed (others in batch unaffected)"
}

process_batch_jobs() {
  if [ -z "${CLIP_BATCH_JOBS:-}" ]; then
    say "no CLIP_BATCH_JOBS — nothing to render"
    return 0
  fi

  local count
  count=$(printf '%s' "$CLIP_BATCH_JOBS" | node "$CLIP_HELPERS" jobs-count)
  say "batch-highlights: ${count} job(s) queued"

  # Wait for cs2 to be render-ready:
  #   GSI fired at least once → demo is actually loaded (else seek
  #     lands on tick 0 of an unloaded demo, captures black)
  #   demoui_hidden=true → spec-server delivered the demoui-toggle
  #     post-GSI (else first render captures the panorama panel)
  # No timeout — the parent k8s Job's activeDeadlineSeconds is the
  # ultimate ceiling.
  say "waiting for demo-ready (GSI + demoui_hidden)"
  local waited=0
  while :; do
    local s ready
    s=$(curl --fail --silent --show-error --max-time 5 \
            "${SPEC_SERVER_URL:-http://127.0.0.1:1350}/demo/state" \
        || true)
    if [ -n "$s" ]; then
      ready=$(printf '%s' "$s" | node "$CLIP_HELPERS" demoui-hidden)
      [ "$ready" = "1" ] && break
    fi
    waited=$((waited + 1))
    [ $((waited % 15)) -eq 0 ] && say "  still waiting (${waited}s)"
    sleep 1
  done
  say "demo ready after ${waited}s"

  local idx
  for idx in $(seq 0 $((count - 1))); do
    local job_json
    if ! job_json=$(printf '%s' "$CLIP_BATCH_JOBS" \
                      | node "$CLIP_HELPERS" jobs-at "$idx"); then
      say "  WARN failed to extract job at index $idx"
      continue
    fi
    batch_render_one_job "$job_json"
  done

  say "batch-highlights: drained ${count} job(s) — exiting"
}
