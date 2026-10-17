# shellcheck shell=bash
# shellcheck disable=SC2016  # stub and t_run bodies expand in their child shells
# Standalone driver for the complete nade-clip CLI; no inline-driver dependency.
# Optional fault controls: NADE_CAPTURE_DEATH_MODE=gpu|all kills the actual
# capture at render_go; NADE_CAPTURE_UNUSABLE=first|all creates an empty file.
# NADE_TRACE_EXEC=1 records process/trap/approach state through the exec redo;
# NADE_CANCEL_ON_REDO=1 returns cancelled on the rerun status GET.
# The parent uses the batch subshell/wait shape and records its status/env.

_nade_kind() {
  local last="${!#}"
  case "$last" in
    -) printf trial ;;
    *.delivery.mp4) printf delivery ;;
    *.jpg|*.webp) printf still ;;
    *) printf other ;;
  esac
}

_nade_encoder() {
  local prev='' arg
  for arg in "$@"; do
    if [ "$prev" = -c:v ]; then printf '%s' "$arg"; return; fi
    prev="$arg"
  done
}

_nade_json_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '"%s"' "$value"
}

_nade_stub() {
  local name="$1" body="$2"
  {
    printf '#!/usr/bin/env bash\n'
    declare -f _nade_kind _nade_encoder _nade_json_quote
    printf '%s\n' "$body"
  } > "$T_BIN/$name"
  chmod +x "$T_BIN/$name"
}

nade_case() {
  t_case "$1"
  mkdir -p "$T_TMP/nade"
  : > "$T_TMP/nade/console.log"
  _nade_stub node 'shift
op="${1:-}"; shift || true
case "$op" in
  status-field) value=$(cat); if [ "$value" = cancelled ]; then echo cancelled; else echo rendering; fi ;;
  nade-timeline)
    if [ "${NADE_TRACE_EXEC:-0}" = 1 ]; then
      bytes=$(wc -c); printf "timeline pid=%s redo=%s bytes=%s\n" "$PPID" "${NADE_CPU_REDO:-0}" "$bytes" >> "$T_TMP/nade/lifecycle"
    fi
    printf "0\t+attack\n50\t-attack\n" ;;
  status-body)
    printf "{"; sep=""
    for item in "$@"; do
      printf "%s" "$sep"; _nade_json_quote "${item%%=*}"; printf ":"; _nade_json_quote "${item#*=}"; sep=,
    done
    printf "}\n" ;;
  *) exit 1 ;;
esac'
  _nade_stub curl 'body="" url="" read_body=0 write_code=0 upload="" data_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --data) body="$2"; shift ;;
    --data-binary) if [ "$2" = @- ]; then read_body=1; else data_file="${2#@}"; fi; shift ;;
    --write-out) write_code=1; shift ;;
    --upload-file) upload="$2"; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
[ "$read_body" = 0 ] || body=$(cat)
case "$url" in
  */demo/exec)
    printf "%s\n" "$body" >> "$T_TMP/nade/execs"
    case "$body" in
      *"say /render_stage "*)
        printf "[5stack-render] staged lineup=%s x=0 y=0 z=0 dz=0 pitch=0 yaw=0 lean=0 v=1\n" "$NADE_LINEUP_ID" >> "$NADE_OUT_DIR/$NADE_RENDER_JOB_ID.events" ;;
      *"say /render_go "*)
        if [ -n "${NADE_CAPTURE_DEATH_MODE:-}" ]; then
          pid=$(cat "$T_TMP/nade/capture.pid" 2>/dev/null || true)
          enc=$(cat "$T_TMP/nade/capture.encoder" 2>/dev/null || true)
          if [ "$NADE_CAPTURE_DEATH_MODE" = all ] || [ "$enc" != x264enc ]; then
            if [ "${pid:-0}" -gt 1 ] 2>/dev/null; then
              printf "die %s pid=%s\n" "$enc" "$pid" >> "$T_TMP/nade/lifecycle"
              kill -TERM "$pid" 2>/dev/null || true
            fi
          fi
        fi
        for kind in stance stance_eyes aim aim_pin aim_close landing; do
          printf "[5stack-render] still lineup=%s kind=%s t=100\n" "$NADE_LINEUP_ID" "$kind"
        done >> "$NADE_OUT_DIR/$NADE_RENDER_JOB_ID.events"
        for event in act thrown detonated done; do
          printf "[5stack-render] %s lineup=%s x=0 y=0 z=0 release_drift=0\n" "$event" "$NADE_LINEUP_ID"
        done >> "$NADE_OUT_DIR/$NADE_RENDER_JOB_ID.events" ;;
    esac ;;
  */status)
    if [ -n "$body" ]; then printf "%s\n" "$body" >> "$T_TMP/nade/statuses"
    elif [ "${NADE_CANCEL_ON_REDO:-0}:${NADE_CPU_REDO:-0}" = 1:1 ]; then echo cancelled; fi ;;
esac
if [ -n "$upload" ]; then
  printf "%s bytes=%s\n" "${url##*/}" "$(stat -c %s "$upload")" >> "$T_TMP/nade/uploads"
elif [ -n "$data_file" ]; then
  printf "%s bytes=%s\n" "${url##*/}" "$(stat -c %s "$data_file")" >> "$T_TMP/nade/uploads"
fi
if [ "$write_code" = 1 ]; then printf 200; fi'
  _nade_stub gst-launch-1.0 '[ "${1:-}" = -q ] && exit "${NADE_GST_TRIAL_RC:-0}"
out=""
for arg in "$@"; do case "$arg" in location=*) out="${arg#location=}" ;; esac; done
if [ -n "$out" ]; then
  mkdir -p "${out%/*}"
  bytes=2048
  if [ "${NADE_CAPTURE_UNUSABLE:-}" = all ] || { [ "${NADE_CAPTURE_UNUSABLE:-}" = first ] && [ "${NADE_CPU_REDO:-0}" != 1 ]; }; then bytes=0; fi
  head -c "$bytes" /dev/zero > "$out"
  if [ "${NADE_TRACE_EXEC:-0}" = 1 ] || [ -n "${NADE_CAPTURE_DEATH_MODE:-}" ]; then
    enc=""; for arg in "$@"; do case "$arg" in nvcudah*enc|nvh*enc|va*enc|x264enc) enc="$arg" ;; esac; done
    printf "%s\n" "$$" > "$T_TMP/nade/capture.pid"
    printf "%s\n" "$enc" > "$T_TMP/nade/capture.encoder"
    printf "%s\n" "$enc" >> "$T_TMP/nade/capture.encoders"
    printf "capture %s pid=%s redo=%s\n" "$enc" "$$" "${NADE_CPU_REDO:-0}" >> "$T_TMP/nade/lifecycle"
  fi
fi
if [ "${NADE_GST_EARLY:-0}" = 1 ]; then exit 1; fi
exec env --default-signal=INT sleep 3600'
  _nade_stub ffmpeg 'printf -v argv "%q " "$@"
printf "%s\n" "${argv% }" >> "$T_TMP/nade/ffmpeg.argv"
kind=$(_nade_kind "$@"); enc=$(_nade_encoder "$@"); last="${!#}"
if [ "$kind" = trial ]; then
  case " ${NADE_FAIL_TRIAL:-} " in *" $enc "*) exit "${NADE_TRIAL_RC:-1}" ;; esac
  exit 0
fi
if [ "$kind" = delivery ]; then
  rung="$enc"
  if [ "$enc" = h264_nvenc ] && [[ " $* " == *" -b_ref_mode "* ]]; then rung=nvenc-bref; fi
  case " ${NADE_FAIL_ENC:-} " in *" $rung "*) exit 1 ;; esac
  head -c 3072 /dev/zero > "$last"
elif [ "$kind" = still ]; then
  head -c 2048 /dev/zero > "$last"
fi'
  _nade_stub ffprobe 'echo 2.000000'
  _nade_stub gst-inspect-1.0 'exit 1'
  _nade_stub pgrep 'case "$*" in *linuxsteamrt64/cs2*) echo 4242 ;; *) exit 1 ;; esac'
  _nade_stub pkill 'if [ "${1:-}" = -P ]; then
  for pid in $(cat "/proc/$2/task/$2/children" 2>/dev/null); do kill -TERM "$pid" 2>/dev/null || true; done
fi'
}

nade_render() {
  rm -f "$T_TMP/nade/ffmpeg.argv" "$T_TMP/nade/execs" "$T_TMP/nade/statuses" "$T_TMP/nade/uploads" "$T_TMP/nade/released"
  : > "$T_TMP/nade/console.log"
  t_run NADE_RENDER_JOB_ID=0123abcd-1111-2222-3333-444455556666 \
    NADE_LINEUP_ID=abcd0123-1111-2222-3333-444455556666 NADE_RENDER_TOKEN=test-token \
    STATUS_API_BASE=http://status.invalid SPEC_SERVER_URL=http://spec.invalid \
    NADE_NADE_TYPE=smoke NADE_HAS_SEED=1 NADE_CMD_JOIN= \
    NADE_OUT_DIR="$T_TMP/nade" CS2_CONSOLE_LOG="$T_TMP/nade/console.log" \
    CS2_FATAL_SENTINEL="$T_TMP/nade/fatal" NADE_CS2_RELEASE_MARKER="$T_TMP/nade/released" \
    CLIP_CAPTURE_METHOD=ximagesrc DISPLAY=:99 GS_PROBE_CACHE="$T_TMP/gst-probes.env" \
    GS_NVENC_PICK=nvcudah264enc NADE_OUTPUT_DIMS=1920x1080 NADE_OUTPUT_FPS=60 \
    NADE_STAGE_TIMEOUT_MS=2000 NADE_STAGE_ATTEMPTS=1 NADE_UNKNOWN_LINEUP_RETRIES=0 \
    NADE_MAX_CLIP_MS=6000 NADE_PIN_PULL_MS=1 NADE_POLL_MS=5 "$@" -- \
    'if [ "${NADE_TRACE_EXEC:-0}" = 1 ]; then
  export BASH_ENV="$T_TMP/nade/bash-env"
  cat > "$BASH_ENV" <<'"'"'NADE_BASH_ENV'"'"'
case "$0" in */nade-clip.sh)
  marker=0; [ -e "$LOG_DIR/cpu-fallback" ] && marker=1
  release=0; [ -e "$NADE_CS2_RELEASE_MARKER" ] && release=1
  approach=0; [ -s "$NADE_APPROACH_FILE" ] && approach=1
  printf "shell pid=%s redo=%s marker=%s released=%s approach=%s\n" "$$" "${NADE_CPU_REDO:-0}" "$marker" "$release" "$approach" >> "$T_TMP/nade/lifecycle"
  exec 9>> "$T_TMP/nade/xtrace"
  BASH_XTRACEFD=9
  PS4="trace pid=$$ redo=${NADE_CPU_REDO:-0} "
  set -x
  ;;
esac
NADE_BASH_ENV
fi
( bash "$GS_REPO/src/lib/nade-clip.sh" ) > "$T_TMP/nade/render.log" 2>&1 &
nade_child=$!
printf "%s\n" "$nade_child" > "$T_TMP/nade/waited.pid"
nade_rc=0; wait "$nade_child" || nade_rc=$?
printf "wait rc=%s redo=%s\n" "$nade_rc" "${NADE_CPU_REDO-unset}" >> "$T_TMP/nade/parent"
exit "$nade_rc"'
  NADE_RC="$T_RC"
  NADE_LOG="$(cat "$T_TMP/nade/render.log" 2>/dev/null)"
}

nade_calls() {
  local requested="$1" line
  local -a args
  [ -f "$T_TMP/nade/ffmpeg.argv" ] || return 0
  while IFS= read -r line; do
    eval "args=($line)"
    [ "$(_nade_kind "${args[@]}")" != "$requested" ] || printf '%s\n' "$line"
  done < "$T_TMP/nade/ffmpeg.argv"
}

nade_encoders() {
  local line
  local -a args
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    eval "args=($line)"
    _nade_encoder "${args[@]}"; printf '\n'
  done < <(nade_calls delivery)
}

nade_execs() { cat "$T_TMP/nade/execs" 2>/dev/null || true; }
nade_statuses() { cat "$T_TMP/nade/statuses" 2>/dev/null || true; }
nade_uploads() { cat "$T_TMP/nade/uploads" 2>/dev/null || true; }

# Delivery argv is the changed interface. Stills have wall-clock offsets and keep
# their separate call log; status and uploaded bytes prove terminal completion.
nade_golden_text() {
  local text dash
  dash=$(printf '\342\200\224')
  text=$(printf 'rc=%s\n== delivery argv\n%s\n== delivery log\n%s\n== uploads\n%s\n== status\n%s\n' \
    "$NADE_RC" "$(nade_calls delivery)" \
    "$(grep 'delivery encode' <<< "$NADE_LOG" | grep -v -F 'delivery encode: encoder=')" \
    "$(nade_uploads)" "$(nade_statuses)")
  printf '%s' "${text//"$dash"/@EMDASH@}"
}
