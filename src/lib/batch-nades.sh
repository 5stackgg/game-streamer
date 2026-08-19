# shellcheck shell=bash
# Drain NADE_BATCH_JOBS against one running cs2 connected to one nade practice
# server. Sourced by run-nades.sh. Per-job failures never halt the batch —
# nade-clip.sh posts its own terminal status.
#
# NADE_BATCH_JOBS is a JSON array; each entry is
#   { "job_id": "<uuid>", "token": "<session token>", "spec": { ... } }
# and spec carries the nade_lineups row the pod needs (column names verbatim):
#   lineup_id, lineup_name, map_name, nade_type ("Smoke"|"Flash"|
#   "HighExplosive"|"Molotov"|"Decoy"), side, origin_x/y/z, eye_z, view_yaw,
#   view_pitch, flight_time_ms, confidence, plugin_runtime, and either
#   has_seed:true|false or the six initial_pos_*/initial_vel_* values,
#   plus output: { resolution: "720p"|"1080p", fps: <int> }.
#
# lineup_name is load-bearing: the practice plugin resolves `.load <query>` by
# name, it has no id lookup.

CLIP_HELPERS="$LIB_DIR/clip-helpers.mjs"

: "${NADE_SESSION_READY_TIMEOUT:=300}"
: "${NADE_BATCH_MAX_TAILS:=2}"
: "${NADE_BATCH_TAIL_OVERLAP:=1}"

nade_post_job_status() {
  local job_id="$1" token="$2"; shift 2
  local body
  body=$(node "$CLIP_HELPERS" status-body "$@" 2>/dev/null) || return 0
  curl --fail --silent --show-error --max-time 10 \
       --header "x-origin-auth: ${job_id}:${token}" \
       --header "content-type: application/json" \
       --data "$body" \
       --output /dev/null \
       "${STATUS_API_BASE}/nade-renders/${job_id}/status" \
    || say "  WARN status post failed for $job_id"
}

nade_fail_job() {
  nade_post_job_status "$1" "$2" "status=error" "error=$3"
}

nade_skip_job() {
  nade_post_job_status "$1" "$2" "status=${NADE_SKIP_STATUS:-skipped}" \
    "skip_reason=$3" "error=$3"
}

nade_render_one_job() {
  local job_json="$1"

  local -a F=()
  readarray -d '' -t F < <(printf '%s' "$job_json" | node "$CLIP_HELPERS" nade-fields)
  local job_id="${F[0]:-}" token="${F[1]:-}" lineup_id="${F[2]:-}" \
        lineup_name="${F[3]:-}" map_name="${F[4]:-}" nade_type="${F[5]:-}" \
        side="${F[6]:-}" origin="${F[7]:-}" eye_z="${F[8]:-}" \
        view_yaw="${F[9]:-}" view_pitch="${F[10]:-}" flight_ms="${F[11]:-0}" \
        has_seed="${F[12]:-0}" confidence="${F[13]:-}" runtime="${F[14]:-}" \
        output_dims="${F[15]:-}" output_fps="${F[16]:-}"

  if [ -z "$job_id" ] || [ -z "$token" ]; then
    say "  skipping malformed nade job blob"
    return 0
  fi
  if [ -z "$lineup_name" ]; then
    say "  $job_id: lineup has no name — the plugin cannot load it"
    nade_skip_job "$job_id" "$token" "lineup has no name; the practice plugin resolves lineups by name only"
    return 0
  fi
  # One server session = one map. A lineup for another map can't be filmed
  # here, and re-loading maps mid-batch would defeat the point of the session.
  if [ -n "$map_name" ] && [ -n "$NADE_SESSION_MAP" ] && [ "$map_name" != "$NADE_SESSION_MAP" ]; then
    say "  $job_id: lineup is on ${map_name}, this session is on ${NADE_SESSION_MAP} — skipping"
    nade_skip_job "$job_id" "$token" "practice server is on ${NADE_SESSION_MAP}, lineup needs ${map_name}"
    return 0
  fi
  if [ -f "$CS2_FATAL_SENTINEL" ]; then
    local reason; reason=$(head -1 "$CS2_FATAL_SENTINEL" 2>/dev/null)
    say "  $job_id: cs2 session dead from an earlier fatal — skipping (${reason:-unknown})"
    nade_fail_job "$job_id" "$token" "cs2 fatal earlier in batch: ${reason:-unknown}"
    return 0
  fi

  say "nade render: $job_id (${lineup_name})"

  local marker="${NADE_OUT_DIR:-/tmp/game-streamer/nades}/${job_id}.cs2done"
  rm -f "$marker"
  (
    export NADE_RENDER_JOB_ID="$job_id"
    export NADE_RENDER_TOKEN="$token"
    export NADE_LINEUP_ID="${lineup_id:-$job_id}"
    export NADE_LINEUP_NAME="$lineup_name"
    export NADE_MAP_NAME="$map_name"
    export NADE_NADE_TYPE="$nade_type"
    export NADE_SIDE="$side"
    export NADE_ORIGIN="$origin"
    export NADE_EYE_Z="$eye_z"
    export NADE_VIEW_YAW="$view_yaw"
    export NADE_VIEW_PITCH="$view_pitch"
    export NADE_FLIGHT_TIME_MS="$flight_ms"
    export NADE_HAS_SEED="$has_seed"
    export NADE_CONFIDENCE="$confidence"
    export NADE_PLUGIN_RUNTIME="${runtime:-${NADE_PLUGIN_RUNTIME:-swiftlys2}}"
    export NADE_OUTPUT_DIMS="$output_dims"
    export NADE_OUTPUT_FPS="$output_fps"
    export NADE_CS2_RELEASE_MARKER="$marker"
    export SPEC_SERVER_URL="${SPEC_SERVER_URL:-http://127.0.0.1:1350}"
    bash "$LIB_DIR/nade-clip.sh"
  ) &
  local pid=$!

  if [ "$NADE_BATCH_TAIL_OVERLAP" != "1" ]; then
    wait "$pid" || say "  job $job_id failed (others in batch unaffected)"
    rm -f "$marker"
    return 0
  fi

  # cs2 is only needed up to the encode; the render touches the marker right
  # after, so the next lineup can be loaded while this one uploads.
  while kill -0 "$pid" 2>/dev/null && [ ! -f "$marker" ]; do
    sleep 0.5
  done
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" || say "  job $job_id failed (others in batch unaffected)"
    rm -f "$marker"
    return 0
  fi
  say "  job $job_id: cs2 released — upload tail continues in background"
  TAIL_PIDS+=("$pid")
  TAIL_JOBS+=("$job_id")
  TAIL_MARKERS+=("$marker")
}

reap_oldest_nade_tail() {
  [ "${#TAIL_PIDS[@]}" -eq 0 ] && return 0
  local pid="${TAIL_PIDS[0]}" job="${TAIL_JOBS[0]}" marker="${TAIL_MARKERS[0]}"
  wait "$pid" || say "  job $job failed (others in batch unaffected)"
  rm -f "$marker"
  TAIL_PIDS=("${TAIL_PIDS[@]:1}")
  TAIL_JOBS=("${TAIL_JOBS[@]:1}")
  TAIL_MARKERS=("${TAIL_MARKERS[@]:1}")
}

# Connected, in-game and alive is the only state in which `.load` does
# anything, so the batch waits for GSI to say so before the first lineup.
# die() fans the failure out to every job, so a server that never comes up is
# reported per-lineup instead of leaving rows stuck in-flight.
wait_for_nade_session() {
  local waited=0 line age health map_name
  NADE_SESSION_MAP=""
  say "waiting for the practice server (GSI + spawned player)"
  while :; do
    line=$(curl --fail --silent --max-time 5 "${SPEC_SERVER_URL:-http://127.0.0.1:1350}/nade/self" || true)
    if [ -n "$line" ]; then
      IFS='|' read -r age _sid _team health _rest <<<"$line"
      case "$age" in
        ''|-1|*[!0-9]*) ;;
        *)
          if [ "$age" -le "${NADE_GSI_MAX_AGE_MS:-2000}" ] \
             && [ "${health:-0}" -gt 0 ] 2>/dev/null; then
            map_name=$(curl --fail --silent --max-time 5 \
                "${SPEC_SERVER_URL:-http://127.0.0.1:1350}/demo/state" \
              | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s)?.gsi?.map_name??"")}catch{}})' \
              || true)
            NADE_SESSION_MAP="$map_name"
            say "practice server ready after ${waited}s (map=${NADE_SESSION_MAP:-?})"
            return 0
          fi
          ;;
      esac
    fi
    if [ "$waited" -ge "$NADE_SESSION_READY_TIMEOUT" ]; then
      die "never spawned on the practice server within ${NADE_SESSION_READY_TIMEOUT}s (wrong password, server down, or the client is stuck in team select)"
    fi
    waited=$((waited + 1))
    [ $((waited % 15)) -eq 0 ] && say "  still waiting (${waited}s)"
    sleep 1
  done
}

process_nade_jobs() {
  if [ -z "${NADE_BATCH_JOBS:-}" ]; then
    say "no NADE_BATCH_JOBS — nothing to render"
    return 0
  fi

  rm -f "$CS2_FATAL_SENTINEL"
  mkdir -p "${NADE_OUT_DIR:-/tmp/game-streamer/nades}"

  local count
  count=$(printf '%s' "$NADE_BATCH_JOBS" | node "$CLIP_HELPERS" jobs-count)
  say "batch-nades: ${count} lineup(s) queued"

  wait_for_nade_session

  local -a TAIL_PIDS=() TAIL_JOBS=() TAIL_MARKERS=()
  local idx job_json
  for idx in $(seq 0 $((count - 1))); do
    if ! job_json=$(printf '%s' "$NADE_BATCH_JOBS" \
                      | node "$CLIP_HELPERS" jobs-at "$idx"); then
      say "  WARN failed to extract nade job at index $idx"
      continue
    fi
    while [ "${#TAIL_PIDS[@]}" -ge "$NADE_BATCH_MAX_TAILS" ]; do
      say "  ${#TAIL_PIDS[@]} upload tail(s) pending — reaping oldest before the next lineup"
      reap_oldest_nade_tail
    done
    nade_render_one_job "$job_json"
  done

  while [ "${#TAIL_PIDS[@]}" -gt 0 ]; do
    say "waiting on ${#TAIL_PIDS[@]} upload tail(s)"
    reap_oldest_nade_tail
  done

  say "batch-nades: drained ${count} lineup(s) — exiting"
}
