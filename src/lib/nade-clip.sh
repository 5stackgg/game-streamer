#!/usr/bin/env bash
# Record ONE nade lineup's throw off a live practice server and upload it.
#
# Unlike inline-clip-render.sh there is no demo to seek: the throw only exists
# as data, so the practice plugin has to reproduce it live. That makes every
# wait here a wait on an observed event (camera arrival, grenade spawn,
# detonation, bloom), never on a sleep that hopes the game kept up.
#
# The plugin can only teleport a LIVE PLAYER pawn (an observer has no pawn to
# move), so this pod joins as a player and films its own first-person view —
# which is also the framing a viewer needs in order to copy the alignment.
#
# Required env: NADE_RENDER_JOB_ID NADE_RENDER_TOKEN STATUS_API_BASE
#               SPEC_SERVER_URL NADE_LINEUP_ID NADE_LINEUP_NAME NADE_NADE_TYPE
# Full job contract: see the header of batch-nades.sh.

set -uo pipefail
SCRIPT_TAG=nade-clip

# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/clip-capture.sh"

require_env NADE_RENDER_JOB_ID NADE_RENDER_TOKEN STATUS_API_BASE \
            SPEC_SERVER_URL NADE_LINEUP_ID NADE_LINEUP_NAME NADE_NADE_TYPE

CLIP_HELPERS="$LIB_DIR/clip-helpers.mjs"
CS2_CONSOLE_LOG="${CS2_CONSOLE_LOG:-$CS2_DIR/game/csgo/console.log}"

LOG_PREFIX="[nade ${NADE_RENDER_JOB_ID:0:8}]"
say() { printf '%s %s\n' "$LOG_PREFIX" "$*" >&2; }

# Lineup spec (all supplied per job by batch-nades.sh).
: "${NADE_MAP_NAME:=}"
: "${NADE_SIDE:=}"
: "${NADE_ORIGIN:=}"
: "${NADE_EYE_Z:=}"
: "${NADE_VIEW_YAW:=}"
: "${NADE_VIEW_PITCH:=}"
: "${NADE_FLIGHT_TIME_MS:=0}"
: "${NADE_HAS_SEED:=0}"
: "${NADE_CONFIDENCE:=}"
: "${NADE_PLUGIN_RUNTIME:=swiftlys2}"

# Plugin verbs. Swiftly registers them as sw_<verb>, CounterStrikeSharp as
# css_<verb>; both also answer to the chat form (`say .load ...`) if a future
# build stops forwarding the console name. {name} expands to the lineup name,
# which is what `.load` matches on — the plugin has no id lookup.
# Escaped closing brace: an unescaped `{name}` inside `${VAR:=...}` ends the
# expansion early and the default silently truncates to "sw_load {name".
: "${NADE_CMD_PREFIX:=sw_}"
: "${NADE_CMD_LOAD:=${NADE_CMD_PREFIX}load {name\}}"
: "${NADE_CMD_THROW:=${NADE_CMD_PREFIX}rethrow}"
# Only the plugin's connect gate is automatic — nothing puts this client on a
# team, and a client in team-select has no pawn to teleport. `=` not `:=` so
# the api can switch the join off with an explicitly empty value.
case "$(printf '%s' "${NADE_SIDE:-}" | tr '[:upper:]' '[:lower:]')" in
  t|terrorist) NADE_JOIN_TEAM=2 ;;
  *)           NADE_JOIN_TEAM=3 ;;
esac
: "${NADE_CMD_JOIN=jointeam ${NADE_JOIN_TEAM}}"

: "${NADE_OUT_DIR:=/tmp/game-streamer/nades}"
: "${NADE_OUTPUT_DIMS:=1920x1080}"
: "${NADE_OUTPUT_FPS:=60}"
: "${NADE_VIDEO_KBPS:=24000}"
: "${NADE_CLIP_AUDIO:=1}"
: "${NADE_SKIP_STATUS:=skipped}"

# Camera arrival tolerances. The teleport is exact (the plugin re-applies the
# angles for two frames after it), so anything outside these means the teleport
# did not happen — not that it was imprecise.
: "${NADE_POS_TOLERANCE:=8}"
: "${NADE_ANGLE_TOLERANCE_DEG:=3}"
: "${NADE_CAMERA_CONFIRM_MS:=15000}"
: "${NADE_LOAD_RETRY_MS:=3000}"

: "${NADE_PREROLL_MS:=1200}"
: "${NADE_THROW_CONFIRM_MS:=4000}"
# Detonation deadline scales off the lineup's RECORDED flight time: a smoke
# that really takes 4s must not be cut at a generic 3s, and a pop-flash must
# not hold the server for 20s waiting on something that already happened.
: "${NADE_DETONATE_FACTOR:=2}"
: "${NADE_DETONATE_SLACK_MS:=2000}"
: "${NADE_DETONATE_MIN_MS:=3000}"
: "${NADE_SMOKE_BLOOM_MS:=2600}"
: "${NADE_INFERNO_HOLD_MS:=3000}"
: "${NADE_TAIL_MS:=1200}"
: "${NADE_MAX_CLIP_MS:=30000}"
: "${NADE_POLL_MS:=100}"
: "${NADE_GSI_MAX_AGE_MS:=2000}"

# Console.log line that proves the grenade went off. The practice plugin prints
# nothing for a re-emitted (ghost) throw today, so this is empty by default and
# the GSI grenade feed is the only automatic signal — see the availability
# check below, which refuses to guess.
: "${NADE_DETONATE_LOG_RE:=}"
: "${NADE_ALLOW_TIMED_DETONATION:=0}"

CLIP_OUTPUT_DIMS="$NADE_OUTPUT_DIMS"
CLIP_OUTPUT_FPS="$NADE_OUTPUT_FPS"
CLIP_OUT_DIR="$NADE_OUT_DIR"
export CLIP_OUTPUT_DIMS CLIP_OUTPUT_FPS CLIP_OUT_DIR

NADE_CLIP_FILE="$NADE_OUT_DIR/${NADE_RENDER_JOB_ID}.mp4"
NADE_THUMB_FILE="$NADE_OUT_DIR/${NADE_RENDER_JOB_ID}.jpg"
NADE_REACHED_TERMINAL=0

if [ -n "${EPOCHREALTIME:-}" ]; then
  now_ms() { local t="${EPOCHREALTIME//[!0-9]/}"; printf -v "$1" '%s' "${t:0:${#t}-3}"; }
else
  now_ms() { printf -v "$1" '%s' "$(date +%s%3N)"; }
fi

poll_sleep() { sleep "$(awk -v ms="$NADE_POLL_MS" 'BEGIN{printf "%.3f", ms/1000}')"; }

json_body() { node "$CLIP_HELPERS" status-body "$@"; }

api_status() {
  local body
  body=$(json_body "$@") || return 0
  curl --fail --silent --show-error --max-time 10 \
       --header "x-origin-auth: ${NADE_RENDER_JOB_ID}:${NADE_RENDER_TOKEN}" \
       --header "content-type: application/json" \
       --data "$body" \
       --output /dev/null \
       "${STATUS_API_BASE}/nade-renders/${NADE_RENDER_JOB_ID}/status" \
    || say "WARN status post failed: $*"
}

die_failed() {
  say "ERROR: $1"
  stop_clip_capture
  api_status "status=error" "error=$1"
  NADE_REACHED_TERMINAL=1
  exit 1
}

# A lineup we cannot reproduce EXACTLY is reported, never approximated: a
# preview of a different throw than the one the lineup describes is worse than
# no preview at all. exit 0 so the rest of the batch still drains.
die_skipped() {
  say "SKIP: $1"
  stop_clip_capture
  api_status "status=${NADE_SKIP_STATUS}" "skip_reason=$1" "error=$1"
  NADE_REACHED_TERMINAL=1
  exit 0
}

spec_post() {
  local path="$1" body="${2:-{\}}" http_code
  http_code=$(printf '%s' "$body" \
    | curl --silent --show-error --max-time 5 \
        --header "content-type: application/json" \
        --data-binary @- \
        --write-out "%{http_code}" \
        --output /dev/null \
        "${SPEC_SERVER_URL}${path}" \
    || echo "000")
  case "$http_code" in
    200|204) return 0 ;;
    *) say "WARN spec POST $path -> $http_code (body=$body)"; return 1 ;;
  esac
}

# Console commands reach cs2 through spec-server's exec-cfg path (a cfg file
# swap + one keypress), the same channel the clip renderer drives the demo
# with. The plugin's verbs are client commands, so cs2 forwards them upstream.
cs2_exec() {
  local cmd="$1" body
  body=$(json_body "cmd=$cmd") || return 1
  say "  exec: $cmd"
  spec_post /demo/exec "$body"
}

cs2_exec_template() {
  local tmpl="$1"
  [ -z "$tmpl" ] && return 0
  tmpl="${tmpl//\{name\}/\"$NADE_LINEUP_NAME\"}"
  tmpl="${tmpl//\{lineup\}/$NADE_LINEUP_ID}"
  cs2_exec "$tmpl"
}

console_log_size() {
  stat -c '%s' "$CS2_CONSOLE_LOG" 2>/dev/null \
    || stat -f '%z' "$CS2_CONSOLE_LOG" 2>/dev/null \
    || echo 0
}

# True when $2 matched console.log AFTER byte offset $1. The offset is taken
# before the command that should produce the line, so a line left over from an
# earlier lineup can never satisfy the wait.
console_log_match() {
  local since="$1" re="$2"
  [ -z "$re" ] && return 1
  [ -f "$CS2_CONSOLE_LOG" ] || return 1
  tail -c "+$((since + 1))" "$CS2_CONSOLE_LOG" 2>/dev/null \
    | grep -aqE "$re"
}

# GSI names for the 5stack e_utility_types values.
nade_gsi_type() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    smoke|smokegrenade)             printf 'smoke' ;;
    flash|flashbang)                printf 'flashbang' ;;
    highexplosive|he|hegrenade|frag) printf 'frag' ;;
    molotov|incendiary|firebomb)    printf 'firebomb' ;;
    decoy)                          printf 'decoy' ;;
    *)                              printf '' ;;
  esac
}

read_watch() {
  local line
  line=$(curl --fail --silent --max-time 5 "${SPEC_SERVER_URL}/nade/watch" || true)
  [ -z "$line" ] && return 1
  IFS='|' read -r _W_ARMED _W_AGE _W_SINCE W_THROWN W_DETONATED W_BLOOM _W_ACTIVE W_TYPE W_BLOCKS \
    <<<"$line"
  case "${W_BLOOM:-}" in ''|*[!0-9]*) W_BLOOM=0 ;; esac
  return 0
}

read_self() {
  local line
  line=$(curl --fail --silent --max-time 5 "${SPEC_SERVER_URL}/nade/self" || true)
  [ -z "$line" ] && return 1
  IFS='|' read -r S_AGE _S_STEAMID _S_TEAM S_HEALTH _S_ACTIVITY S_X S_Y S_Z S_FX S_FY S_FZ \
    <<<"$line"
  return 0
}

on_exit() {
  local rc=$?
  stop_clip_capture
  spec_post /nade/watch '{"armed": false}' >/dev/null 2>&1 || true
  rm -f "$NADE_THUMB_FILE"
  if [ "$rc" -ne 0 ] && [ "$NADE_REACHED_TERMINAL" != "1" ]; then
    api_status "status=error" \
      "error=nade render exited rc=${rc} before reaching terminal status" || true
  fi
}
trap 'on_exit' EXIT

# ---------------------------------------------------------------------------

PRE_STATUS=$(curl --fail --silent --show-error --max-time 5 \
  --header "x-origin-auth: ${NADE_RENDER_JOB_ID}:${NADE_RENDER_TOKEN}" \
  "${STATUS_API_BASE}/nade-renders/${NADE_RENDER_JOB_ID}/status" \
  | node "$CLIP_HELPERS" status-field)
if [ "$PRE_STATUS" = "cancelled" ]; then
  say "job already cancelled — skipping (no work, no error)"
  NADE_REACHED_TERMINAL=1
  exit 0
fi

GSI_TYPE=$(nade_gsi_type "$NADE_NADE_TYPE")
say "============================================================"
say "lineup=${NADE_LINEUP_ID} '${NADE_LINEUP_NAME}'"
say "type=${NADE_NADE_TYPE}(${GSI_TYPE:-?}) map=${NADE_MAP_NAME:-?} side=${NADE_SIDE:-?}"
say "seed=${NADE_HAS_SEED} confidence=${NADE_CONFIDENCE:-?} flight=${NADE_FLIGHT_TIME_MS}ms runtime=${NADE_PLUGIN_RUNTIME}"
say "============================================================"

# --- Everything that makes this lineup unrenderable, checked before we film ---

[ -n "$GSI_TYPE" ] || die_skipped "unknown grenade type '${NADE_NADE_TYPE}'"

# The recorded seed (initial position + velocity) is what makes the re-emitted
# grenade land where the lineup says it does. Without it, and without the
# plugin's own 'exact' confidence, the throw can only be approximated.
case "$NADE_HAS_SEED" in
  1|true|yes) : ;;
  *) die_skipped "lineup has no recorded physics seed (initial position/velocity) — the throw cannot be reproduced exactly" ;;
esac
case "$(printf '%s' "$NADE_CONFIDENCE" | tr '[:upper:]' '[:lower:]')" in
  exact) : ;;
  *) die_skipped "lineup confidence is '${NADE_CONFIDENCE:-unset}', not 'exact' — the plugin refuses to replay it" ;;
esac
# Re-emitting from a seed is a SwiftlyS2-only capability; the CSS build of the
# plugin has no replay path at all and would film an empty room.
case "$(printf '%s' "$NADE_PLUGIN_RUNTIME" | tr '[:upper:]' '[:lower:]')" in
  swiftlys2|swiftly) : ;;
  *) die_skipped "practice server runs ${NADE_PLUGIN_RUNTIME}, which cannot re-emit a stored throw (SwiftlyS2 only)" ;;
esac
if [ -z "$NADE_ORIGIN" ] || [ -z "$NADE_VIEW_YAW" ] || [ -z "$NADE_VIEW_PITCH" ]; then
  die_skipped "lineup is missing its origin/view angles — the camera cannot be verified"
fi
if [ -f "$CS2_FATAL_SENTINEL" ]; then
  die_failed "cs2 session already dead: $(head -1 "$CS2_FATAL_SENTINEL" 2>/dev/null)"
fi

api_status "status=rendering" "progress=0.02"

mkdir -p "$NADE_OUT_DIR"
rm -f "$NADE_CLIP_FILE" "$NADE_THUMB_FILE"

# --- STEP 1: stand where the throw was recorded ------------------------------

say "STEP 1: load lineup + confirm camera"
# Re-joining a team we're already alive on would respawn us mid-batch, so the
# join only fires while there is no live pawn.
join_if_not_spawned() {
  [ -n "$NADE_CMD_JOIN" ] || return 0
  read_self || return 0
  case "${S_HEALTH:-0}" in
    ''|0|*[!0-9]*) cs2_exec "$NADE_CMD_JOIN" ;;
  esac
}
join_if_not_spawned
cs2_exec_template "$NADE_CMD_LOAD"

# Position AND angle both have to match: the alignment is the product, so a
# clip shot from the right spot facing the wrong way is a wrong clip.
CAMERA_FAIL="no GSI player state yet"
CAMERA_FAIL_MEASURED=""
camera_confirmed() {
  read_self || { CAMERA_FAIL="spec-server /nade/self unreachable"; return 1; }
  case "${S_AGE:-}" in ''|-1|*[!0-9]*) CAMERA_FAIL="GSI has not fired yet"; return 1 ;; esac
  if [ "$S_AGE" -gt "$NADE_GSI_MAX_AGE_MS" ]; then
    CAMERA_FAIL="GSI is stale (${S_AGE}ms)"
    return 1
  fi
  case "${S_HEALTH:-0}" in ''|*[!0-9]*) CAMERA_FAIL="no player state"; return 1 ;; esac
  if [ "$S_HEALTH" -le 0 ]; then
    CAMERA_FAIL="not spawned/alive on the server"
    return 1
  fi
  if [ -z "${S_X:-}" ] || [ -z "${S_FX:-}" ]; then
    CAMERA_FAIL="GSI reported no position/forward"
    return 1
  fi
  local rc=0
  awk -v x="$S_X" -v y="$S_Y" -v z="$S_Z" \
      -v fx="$S_FX" -v fy="$S_FY" -v fz="$S_FZ" \
      -v origin="$NADE_ORIGIN" -v eyez="${NADE_EYE_Z:-}" \
      -v yaw="$NADE_VIEW_YAW" -v pitch="$NADE_VIEW_PITCH" \
      -v tol="$NADE_POS_TOLERANCE" -v angtol="$NADE_ANGLE_TOLERANCE_DEG" '
    function abs(v) { return v < 0 ? -v : v }
    BEGIN {
      if (split(origin, o, /[ ,]+/) < 3) exit 1
      if (abs(x - o[1]) > tol || abs(y - o[2]) > tol) exit 2
      # GSI reports the player origin; accept an eye-height reading too rather
      # than depending on which one this cs2 build sends.
      if (abs(z - o[3]) > tol && (eyez == "" || abs(z - eyez) > tol)) exit 2
      rad = 3.14159265358979 / 180
      wx = cos(pitch * rad) * cos(yaw * rad)
      wy = cos(pitch * rad) * sin(yaw * rad)
      wz = -sin(pitch * rad)
      dot = fx * wx + fy * wy + fz * wz
      if (dot > 1) dot = 1
      if (dot < -1) dot = -1
      if (atan2(sqrt(1 - dot * dot), dot) / rad > angtol) exit 3
      exit 0
    }' || rc=$?
  case "$rc" in
    0) return 0 ;;
    2) CAMERA_FAIL="standing at ${S_X},${S_Y},${S_Z}, lineup wants ${NADE_ORIGIN}" ;;
    3) CAMERA_FAIL="looking along ${S_FX},${S_FY},${S_FZ}, lineup wants yaw=${NADE_VIEW_YAW} pitch=${NADE_VIEW_PITCH}" ;;
    *) CAMERA_FAIL="lineup origin '${NADE_ORIGIN}' is malformed" ;;
  esac
  # Every poll overwrites CAMERA_FAIL, so the timeout used to report whichever
  # reason the LAST poll happened to hit -- and the ambient ones (stale GSI, not
  # yet spawned) drown out the one that tells you anything. A reading we could
  # actually measure is the diagnosis; keep it and report that instead.
  CAMERA_FAIL_MEASURED="$CAMERA_FAIL"
  return 1
}

CAMERA_OK=0
WAITED=0
while [ "$WAITED" -lt "$NADE_CAMERA_CONFIRM_MS" ]; do
  if camera_confirmed; then
    CAMERA_OK=1
    say "STEP 1: camera confirmed after ${WAITED}ms at ${S_X},${S_Y},${S_Z}"
    break
  fi
  poll_sleep
  WAITED=$((WAITED + NADE_POLL_MS))
  # `.load` is a no-op while we're still connecting / dead / in freezetime
  # limbo, so re-issue it periodically instead of waiting out the timeout.
  if [ $((WAITED % NADE_LOAD_RETRY_MS)) -lt "$NADE_POLL_MS" ]; then
    join_if_not_spawned
    cs2_exec_template "$NADE_CMD_LOAD"
  fi
done
if [ "$CAMERA_OK" != "1" ]; then
  if [ -n "${CAMERA_FAIL_MEASURED:-}" ]; then
    # We saw the player clearly at least once and they were in the wrong place,
    # so the lineup loaded and the map is right -- this is an alignment problem,
    # not a connection one.
    die_skipped "camera never reached the lineup within ${NADE_CAMERA_CONFIRM_MS}ms: ${CAMERA_FAIL_MEASURED}"
  fi
  die_skipped "camera never reached the lineup within ${NADE_CAMERA_CONFIRM_MS}ms: ${CAMERA_FAIL} — wrong map, not spawned, or the plugin has no lineup named '${NADE_LINEUP_NAME}'"
fi
api_status "status=rendering" "progress=0.15"

# --- STEP 2: arm the grenade watch BEFORE capture ----------------------------
# Anything already in the air (a previous lineup's smoke) must not be mistaken
# for this lineup's throw, so the watch snapshots the world before the throw.

ARM_BODY=$(json_body "type=${GSI_TYPE}")
spec_post /nade/watch "$ARM_BODY" \
  || say "WARN /nade/watch arm failed — only the console-log signal is left"
GSI_GRENADES=0
if read_watch && [ "${W_BLOCKS:-0}" != "0" ]; then
  GSI_GRENADES=1
fi
say "STEP 2: watch armed (gsi grenade feed seen=${GSI_GRENADES}, log_re=${NADE_DETONATE_LOG_RE:+set})"

# --- STEP 3: capture opens on the alignment ----------------------------------
# The still frame of where to stand and what to line up on IS the product, so
# the clip starts before the throw rather than on it.

say "STEP 3: start capture -> $NADE_CLIP_FILE"
if ! start_clip_capture "$NADE_CLIP_FILE" "$NADE_OUTPUT_FPS" "$NADE_VIDEO_KBPS" "$NADE_CLIP_AUDIO"; then
  die_failed "capture failed to start"
fi
wait_clip_capture_ready || true
clip_capture_go
now_ms CAPTURE_START_MS
sleep "$(awk -v ms="$NADE_PREROLL_MS" 'BEGIN{printf "%.3f", ms/1000}')"
api_status "status=rendering" "progress=0.3"

# --- STEP 4: throw, then wait for the detonation to actually happen ----------

THROW_LOG_OFFSET=$(console_log_size)
cs2_exec_template "$NADE_CMD_THROW"
now_ms THROW_MS

DETONATE_DEADLINE_MS=$(awk -v f="$NADE_FLIGHT_TIME_MS" -v k="$NADE_DETONATE_FACTOR" \
  -v slack="$NADE_DETONATE_SLACK_MS" -v floor="$NADE_DETONATE_MIN_MS" 'BEGIN{
    d = f * k + slack
    if (d < floor) d = floor
    printf "%d", d
  }')
say "STEP 4: thrown — detonation deadline ${DETONATE_DEADLINE_MS}ms (recorded flight ${NADE_FLIGHT_TIME_MS}ms)"

THROWN=0
DETONATED=0
BLOOM_MS=0
SEEN_TYPE=""
TIMED_FALLBACK=0
DETONATED_AT_MS=0
while :; do
  now_ms NOW
  ELAPSED=$((NOW - THROW_MS))
  if read_watch; then
    [ "${W_BLOCKS:-0}" != "0" ] && GSI_GRENADES=1
    [ "${W_THROWN:-0}" = "1" ] && THROWN=1
    if [ "${W_DETONATED:-0}" = "1" ]; then
      DETONATED=1
      BLOOM_MS="$W_BLOOM"
      SEEN_TYPE="$W_TYPE"
    fi
  fi
  if [ "$DETONATED" != "1" ] && [ -n "$NADE_DETONATE_LOG_RE" ] \
     && console_log_match "$THROW_LOG_OFFSET" "$NADE_DETONATE_LOG_RE"; then
    DETONATED=1
    THROWN=1
  fi
  if [ "$DETONATED" = "1" ]; then
    now_ms DETONATED_AT_MS
    say "STEP 4: detonation observed after ${ELAPSED}ms (type=${SEEN_TYPE:-$GSI_TYPE})"
    break
  fi
  # No grenade entity a full throw-confirm window after the command, on a
  # server whose grenades we CAN see: the plugin never emitted one.
  if [ "$THROWN" != "1" ] && [ "$GSI_GRENADES" = "1" ] \
     && [ "$ELAPSED" -ge "$NADE_THROW_CONFIRM_MS" ]; then
    die_failed "no grenade appeared within ${NADE_THROW_CONFIRM_MS}ms of ${NADE_CMD_THROW} — the plugin did not re-emit it (np_ghost_projectile off?)"
  fi
  if [ "$ELAPSED" -ge "$DETONATE_DEADLINE_MS" ]; then
    if [ "$NADE_ALLOW_TIMED_DETONATION" = "1" ]; then
      TIMED_FALLBACK=1
      DETONATED=1
      now_ms DETONATED_AT_MS
      say "WARN no detonation signal in ${DETONATE_DEADLINE_MS}ms — falling back to the recorded flight time (NADE_ALLOW_TIMED_DETONATION=1); this clip's timing is UNVERIFIED"
      break
    fi
    die_failed "grenade never detonated within ${DETONATE_DEADLINE_MS}ms and no detonation signal is available (GSI grenade feed seen=${GSI_GRENADES}, NADE_DETONATE_LOG_RE${NADE_DETONATE_LOG_RE:+ set}${NADE_DETONATE_LOG_RE:-" unset"})"
  fi
  if [ $((NOW - CAPTURE_START_MS)) -ge "$NADE_MAX_CLIP_MS" ]; then
    die_failed "clip hit the ${NADE_MAX_CLIP_MS}ms hard cap before detonation"
  fi
  poll_sleep
done
api_status "status=rendering" "progress=0.7"

# --- STEP 5: hold for as long as THIS grenade type stays interesting ---------
# A smoke is held on its GSI-reported effecttime (engine truth); everything
# else gets a fixed tail measured from the OBSERVED detonation, never from the
# throw, so a slow flight can't eat the payoff.

case "${SEEN_TYPE:-$GSI_TYPE}" in
  smoke)
    HOLD_DEADLINE_MS=$((NADE_SMOKE_BLOOM_MS + 3000))
    say "STEP 5: holding for bloom (effecttime >= ${NADE_SMOKE_BLOOM_MS}ms)"
    while :; do
      now_ms NOW
      HELD=$((NOW - DETONATED_AT_MS))
      if read_watch; then
        BLOOM_MS="$W_BLOOM"
      fi
      if [ "$BLOOM_MS" -ge "$NADE_SMOKE_BLOOM_MS" ]; then
        say "STEP 5: bloomed (effecttime=${BLOOM_MS}ms)"
        break
      fi
      # No grenade feed means no effecttime to read: hold the bloom duration
      # from the observed detonation instead.
      if [ "$GSI_GRENADES" != "1" ] && [ "$HELD" -ge "$NADE_SMOKE_BLOOM_MS" ]; then
        say "STEP 5: no GSI grenade feed — held ${HELD}ms from the observed detonation"
        break
      fi
      if [ "$HELD" -ge "$HOLD_DEADLINE_MS" ]; then
        say "WARN bloom never reached ${NADE_SMOKE_BLOOM_MS}ms (last=${BLOOM_MS}ms) — stopping"
        break
      fi
      if [ $((NOW - CAPTURE_START_MS)) -ge "$NADE_MAX_CLIP_MS" ]; then
        say "WARN hit the ${NADE_MAX_CLIP_MS}ms hard cap during bloom"
        break
      fi
      poll_sleep
    done
    ;;
  firebomb|inferno)
    say "STEP 5: holding ${NADE_INFERNO_HOLD_MS}ms of fire spread"
    sleep "$(awk -v ms="$NADE_INFERNO_HOLD_MS" 'BEGIN{printf "%.3f", ms/1000}')"
    ;;
  *)
    say "STEP 5: holding ${NADE_TAIL_MS}ms tail"
    sleep "$(awk -v ms="$NADE_TAIL_MS" 'BEGIN{printf "%.3f", ms/1000}')"
    ;;
esac

say "STEP 6: stop capture"
stop_clip_capture
spec_post /nade/watch '{"armed": false}' || true
api_status "status=rendering" "progress=0.9"

CLIP_BYTES=$(stat -c '%s' "$NADE_CLIP_FILE" 2>/dev/null \
  || stat -f '%z' "$NADE_CLIP_FILE" 2>/dev/null || echo 0)
CLIP_DURATION_S=$(ffprobe -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 "$NADE_CLIP_FILE" 2>/dev/null \
  | awk '{printf "%.2f", $1}')
[ -z "$CLIP_DURATION_S" ] && CLIP_DURATION_S=0
if [ "$(awk -v d="$CLIP_DURATION_S" -v b="$CLIP_BYTES" \
        'BEGIN{print (d >= 1.0 && b > 1024) ? 1 : 0}')" != "1" ]; then
  die_failed "encode produced an unusable clip (${CLIP_BYTES}B, ${CLIP_DURATION_S}s)"
fi
CLIP_DURATION_MS=$(awk -v d="$CLIP_DURATION_S" 'BEGIN{printf "%d", d * 1000}')
say "captured ${CLIP_BYTES}B / ${CLIP_DURATION_S}s"

# cs2 is free from here — the batch loop can start the next lineup while this
# job's upload tail (disk + network only) finishes.
if [ -n "${NADE_CS2_RELEASE_MARKER:-}" ]; then
  : >"$NADE_CS2_RELEASE_MARKER" 2>/dev/null || true
  say "cs2 released — next lineup may start"
fi

# The alignment frame makes the useful poster, so the thumbnail comes from the
# pre-roll rather than from the middle of the flight.
THUMB_SEEK_S=$(awk -v ms="$NADE_PREROLL_MS" -v d="$CLIP_DURATION_S" 'BEGIN{
  t = ms / 2000
  if (t > d / 2) t = d / 2
  printf "%.3f", t
}')
(
  if ffmpeg -y -hide_banner -loglevel warning \
       -ss "$THUMB_SEEK_S" -i "$NADE_CLIP_FILE" -frames:v 1 -q:v 3 \
       "$NADE_THUMB_FILE" 2>/dev/null \
     && [ -s "$NADE_THUMB_FILE" ]; then
    curl --fail --silent --show-error --max-time 60 \
         --header "x-origin-auth: ${NADE_RENDER_JOB_ID}:${NADE_RENDER_TOKEN}" \
         --header "content-type: image/jpeg" \
         --data-binary "@${NADE_THUMB_FILE}" \
         --output /dev/null \
         "${STATUS_API_BASE}/nade-renders/${NADE_RENDER_JOB_ID}/thumbnail" \
      || say "WARN thumbnail upload failed — continuing without one"
  else
    say "WARN ffmpeg thumbnail extraction failed — continuing without one"
  fi
  rm -f "$NADE_THUMB_FILE"
) &
THUMB_BG_PID=$!

api_status "status=uploading" "progress=0.0"
say "POST ${STATUS_API_BASE}/nade-renders/${NADE_RENDER_JOB_ID}/upload"
# --upload-file streams from disk; --data-binary @file would slurp the whole
# clip into RAM alongside every other pending upload tail.
if ! curl --fail --silent --show-error --max-time 900 \
       --header "x-origin-auth: ${NADE_RENDER_JOB_ID}:${NADE_RENDER_TOKEN}" \
       --header "content-type: application/octet-stream" \
       --header "x-clip-duration-ms: ${CLIP_DURATION_MS}" \
       --upload-file "$NADE_CLIP_FILE" \
       --request POST \
       --output /dev/null \
       "${STATUS_API_BASE}/nade-renders/${NADE_RENDER_JOB_ID}/upload"; then
  wait "$THUMB_BG_PID" 2>/dev/null || true
  die_failed "clip upload failed"
fi
# The api only attaches a thumbnail that already exists when the upload
# finalizes, so it has to land before status=done.
wait "$THUMB_BG_PID" 2>/dev/null || true

DONE_ARGS=("status=done" "progress=1.0" "duration_ms=${CLIP_DURATION_MS}")
[ "$TIMED_FALLBACK" = "1" ] && DONE_ARGS+=("unverified_timing=1")
api_status "${DONE_ARGS[@]}"
NADE_REACHED_TERMINAL=1
rm -f "$NADE_CLIP_FILE"
say "done"
