# S3-U11 coordinator checks. Force each stage while using real server processes
# and the shipped identity, status-writing and bounded-stop code.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

fallback_case() {
  t_case "$1"
  t_stub tierc-server 'name="$1"
trap "echo $name-TERM >> \"$T_TMP/events\"; exit 0" TERM
touch "$T_TMP/$name.ready"
while :; do sleep 0.1; done'
}

fallback_run() {
  t_run GS_GPU_VENDOR=amd GS_PROC_ROOT=/proc "$@" -- 'set -uo pipefail
. "$GS_REPO/src/lib/xorg.sh"
export GS_RENDER_NODE=/dev/null
_GS_TIER_PICK="C requested"
_GS_TIER_DISPLAY=:21
trap '\''_tier_c_stop "${_GS_TIER_XW:-}" "${_GS_TIER_WESTON:-}" || true
[ -z "${old:-}" ] || kill -KILL "$old" 2>/dev/null || true
_tier_c_cleanup'\'' EXIT
warn_impl=$(declare -f warn)
eval "${warn_impl/warn/warn_original}"
warn() { printf "warn:%s\n" "$*" >> "$T_TMP/events"; warn_original "$@"; }
kill() {
  case "${1:-}" in -TERM) printf "signal:%s\n" "${2:-}" >> "$T_TMP/events" ;; esac
  builtin kill "$@"
}
_tier_c_start_weston() {
  mkdir -p /tmp/gs-weston
  tierc-server weston & _GS_TIER_WESTON=$!
  for ((i=0;i<30;i++)); do [ -e "$T_TMP/weston.ready" ] && break; sleep 0.1; done
  printf "renderer-last-line\n" > "$LOG_DIR/weston.log"
  if [ "$FALLBACK_MODE" = weston-renderer ]; then
    _tier_c_fail weston-renderer "test renderer" "$LOG_DIR/weston.log"
    return 1
  fi
}
_tier_c_try_displays() {
  tierc-server xwayland & _GS_TIER_XW=$!
  for ((i=0;i<30;i++)); do [ -e "$T_TMP/xwayland.ready" ] && break; sleep 0.1; done
  printf "xwayland-last-line\n" > "$LOG_DIR/xwayland.21.log"
  if [ "$FALLBACK_MODE" = xwayland-failed ]; then
    _tier_c_fail xwayland-failed "test readiness timeout" "$LOG_DIR/xwayland.21.log"
    return 1
  fi
}
_tier_c_selftest() {
  if [ "$FALLBACK_MODE" = vkcube-failed ]; then
    _tier_c_fail vkcube-failed "test device lost" "$LOG_DIR/xwayland.21.log"
    return 1
  fi
}
if [ "$FALLBACK_MODE" = no-render-node ]; then unset GS_RENDER_NODE; fi
if [ "$FALLBACK_MODE" = leftover ]; then
  tierc-server old & old=$!
  for ((i=0;i<30;i++)); do [ -e "$T_TMP/old.ready" ] && break; sleep 0.1; done
  _tier_c_record_pid "$old" "$LOG_DIR/weston.pid"
fi
rc=0
_start_tier_c || rc=$?
printf "rc=%s pick=%s found=%s\n" "$rc" "$(cat "$LOG_DIR/display_tier" 2>/dev/null)" "${XORG_FOUND:-}"
if [ "$rc" = 0 ]; then
  printf "weston-pid=%s xwayland-pid=%s\n" \
    "$(_tier_c_read_pid "$LOG_DIR/weston.pid")" "$(_tier_c_read_pid "$LOG_DIR/xwayland.pid")"
else
  [ ! -e /tmp/gs-weston ] || exit 8
  [ ! -e "$LOG_DIR/weston.pid" ] && [ ! -e "$LOG_DIR/xwayland.pid" ] || exit 9
  if _tier_c_alive "$_GS_TIER_WESTON" || _tier_c_alive "$_GS_TIER_XW"; then exit 10; fi
fi
if [ -n "${old:-}" ] && _tier_c_alive "$old"; then exit 11; fi
cat "$T_TMP/events" 2>/dev/null || true'
}

for mode in no-render-node weston-renderer xwayland-failed vkcube-failed; do
  fallback_case "fallback at $mode"
  fallback_run FALLBACK_MODE="$mode"
  assert_rc 0 'fallback and cleanup complete'
  assert_contains "$T_STDOUT" "rc=1 pick=A fallback:$mode" 'durable fallback line'
  assert_eq 1 "$(grep -c 'tier C fallback:' <<< "$T_STDERR")" 'exactly one stage warning'
  if [ "$mode" = no-render-node ]; then
    assert_not_contains "$T_STDOUT" 'signal:' 'nothing started or signaled'
    assert_not_contains "$T_STDERR" 'last log:' 'no fake last log'
  else
    assert_match 'warn:tier C fallback:.*signal:' "${T_STDOUT//$'\n'/ }" 'reason warning precedes first signal'
    assert_contains "$T_STDERR" 'last log:' 'server last line accompanies reason'
  fi
done

for mode in good leftover; do
  fallback_case "successful coordinator with $mode state"
  fallback_run FALLBACK_MODE="$mode"
  assert_rc 0 'startup and final cleanup succeed'
  assert_contains "$T_STDOUT" 'rc=0 pick=C requested found=:21' 'accepted candidate only'
  assert_match 'weston-pid=[0-9]+ xwayland-pid=[0-9]+' "$T_STDOUT" 'both identities persisted'
  assert_not_contains "$T_STDERR" 'tier C fallback:' 'no fallback warning'
  if [ "$mode" = leftover ]; then
    assert_contains "$T_STDOUT" old-TERM 'previous recorded server stopped first'
  fi
done

fallback_case 'a SIGKILL survivor lock keeps the real tier A walk off its display'
t_stub tierc-survivor 'trap "" TERM; touch "$T_TMP/survivor.ready"; while :; do sleep 0.1; done'
t_stub Xorg 'echo $$ > "$T_TMP/xorg.pid"; touch "$T_TMP/xorg.up"
trap "exit 0" TERM; while :; do sleep 0.1; done'
t_stub xdpyinfo '[ "${2:-}" = :21 ] && [ -e "$T_TMP/xorg.up" ]'
t_run GS_GPU_VENDOR=amd GS_PROC_ROOT=/proc -- 'set -uo pipefail
. "$GS_REPO/src/lib/xorg.sh"
GS_RENDER_NODE=/dev/null
_GS_TIER_PICK="C requested"
DISPLAY=:20
a=""; b=""
trap '\''builtin kill -KILL "${a:-}" "${b:-}" "$(cat "$T_TMP/xorg.pid" 2>/dev/null)" 2>/dev/null || true
wait "${a:-}" "${b:-}" 2>/dev/null || true
rm -f /tmp/.X20-lock /tmp/.X21-lock
_tier_c_cleanup'\'' EXIT
kill() {
  if [ "${1:-}" = -KILL ] && [ "${2:-}" = "$a" ]; then return 0; fi
  builtin kill "$@"
}
_tier_c_start_weston() {
  tierc-server weston & b=$!; _GS_TIER_WESTON=$b
  for ((i=0;i<30;i++)); do [ -e "$T_TMP/weston.ready" ] && break; sleep 0.1; done
}
_tier_c_try_displays() {
  tierc-survivor & a=$!; _GS_TIER_XW=$a
  for ((i=0;i<30;i++)); do [ -e "$T_TMP/survivor.ready" ] && break; sleep 0.1; done
  echo "$a" > /tmp/.X20-lock
  _GS_TIER_DISPLAY=:20
}
_tier_c_selftest() { _tier_c_fail vkcube-failed "test failure with a kernel survivor"; }
started=$SECONDS; rc=0
_start_tier_c || rc=$?
printf "fallback=%s elapsed=%s\n" "$(cat "$LOG_DIR/display_tier")" "$((SECONDS-started))"
[ "$rc" = 1 ] && _tier_c_alive "$a" || exit 8
[ "$(cat /tmp/.X20-lock)" = "$a" ] || exit 9
_xorg_try_displays || exit 10
printf "tier-a-found=%s\n" "$XORG_FOUND"'
assert_rc 0 'fallback and real tier A walk complete'
assert_contains "$T_STDOUT" 'fallback=A fallback:vkcube-failed' 'original fallback reason retained'
assert_match 'elapsed=([0-9]|1[0-9])($|[^0-9])' "$T_STDOUT" 'fallback stop returns below twenty seconds'
assert_contains "$T_STDERR" 'survived SIGKILL (state ' 'survivor is reported'
assert_contains "$T_STDOUT" 'lock owned by live PID' 'real tier A code skips the surviving lock'
assert_contains "$T_STDOUT" tier-a-found=:21 'the next display is used'

t_done
