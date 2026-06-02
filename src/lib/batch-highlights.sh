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

  local job_id token segments output_dims output_fps
  local target_sid current_title target_name target_avatar kills_count map_name round
  job_id=$(printf       '%s' "$job_json" | node "$CLIP_HELPERS" job-id)
  token=$(printf        '%s' "$job_json" | node "$CLIP_HELPERS" job-token)
  segments=$(printf     '%s' "$job_json" | node "$CLIP_HELPERS" job-segments)
  output_dims=$(printf  '%s' "$job_json" | node "$CLIP_HELPERS" job-output-dims)
  output_fps=$(printf   '%s' "$job_json" | node "$CLIP_HELPERS" job-output-fps)
  target_sid=$(printf   '%s' "$job_json" | node "$CLIP_HELPERS" job-first-pov-steamid)
  current_title=$(printf '%s' "$job_json" | node "$CLIP_HELPERS" job-title)
  target_name=$(printf  '%s' "$job_json" | node "$CLIP_HELPERS" job-target-name)
  target_avatar=$(printf '%s' "$job_json" | node "$CLIP_HELPERS" job-target-avatar-url)
  kills_count=$(printf  '%s' "$job_json" | node "$CLIP_HELPERS" job-kills-count)
  map_name=$(printf     '%s' "$job_json" | node "$CLIP_HELPERS" job-map-name)
  round=$(printf        '%s' "$job_json" | node "$CLIP_HELPERS" job-round)

  if [ -z "$job_id" ] || [ -z "$token" ]; then
    say "  skipping malformed job blob"
    return 0
  fi

  say "batch render: $job_id"
  patch_title_from_gsi "$job_id" "$token" "$target_sid" "$current_title"

  # Subshell so the render trap + env don't leak. MATCH_ID is unset
  # because batch pods don't publish a live match capture.
  (
    export CLIP_RENDER_JOB_ID="$job_id"
    export CLIP_RENDER_TOKEN="$token"
    export CLIP_SEGMENTS="$segments"
    export CLIP_OUTPUT_DIMS="$output_dims"
    export CLIP_OUTPUT_FPS="$output_fps"
    export CLIP_TICK_RATE="${DEMO_TICK_RATE:-64}"
    export SPEC_SERVER_URL="${SPEC_SERVER_URL:-http://127.0.0.1:1350}"
    export CLIP_DISPLAY_NAME="$target_name"
    export CLIP_DISPLAY_AVATAR="$target_avatar"
    export CLIP_DISPLAY_TARGET_STEAMID="$target_sid"
    export CLIP_DISPLAY_KILLS="$kills_count"
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
  # Fail fast instead of hanging here forever: this loop otherwise has
  # no ceiling (the k8s Job has no activeDeadlineSeconds). A demo cs2
  # cannot play (e.g. recorded on an older build) logs
  # NETWORK_DISCONNECT_REPLAY_INCOMPATIBLE in console.log and never
  # becomes ready; die() broadcasts status=error to every batch job (so
  # the UI shows the reason) and exits so the Job is reaped and the GPU
  # node frees. DEMO_READY_TIMEOUT is a backstop for any other
  # never-ready cause.
  say "waiting for demo-ready (GSI + demoui_hidden)"
  local console_log="$CS2_DIR/game/csgo/console.log"
  local demo_ready_timeout="${DEMO_READY_TIMEOUT:-300}"
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
    if grep -q 'NETWORK_DISCONNECT_REPLAY_INCOMPATIBLE' "$console_log" 2>/dev/null; then
      die "demo is incompatible with the current CS2 version and can no longer be rendered"
    fi
    if [ "$waited" -ge "$demo_ready_timeout" ]; then
      die "cs2 did not load the demo within ${demo_ready_timeout}s; aborting render"
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
