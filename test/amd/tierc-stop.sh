# S3-U11/U12 process identities and bounded stop behavior.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

stop_run() {
  t_run GS_PROC_ROOT=/proc "$@" -- 'set -uo pipefail
. "$GS_REPO/src/lib/xorg.sh"
trap '\''[ -z "${a:-}" ] || builtin kill -KILL "$a" 2>/dev/null || true
[ -z "${b:-}" ] || builtin kill -KILL "$b" 2>/dev/null || true'\'' EXIT
'"$STOP_BODY"
}

t_case 'clean ordered stop signals Xwayland before weston'
STOP_BODY='bash -c '\''trap "exit 0" TERM; echo ready; while :; do sleep 0.1; done'\'' > "$T_TMP/a" & a=$!
bash -c '\''trap "exit 0" TERM; echo ready; while :; do sleep 0.1; done'\'' > "$T_TMP/b" & b=$!
for ((i=0;i<30;i++)); do [ -s "$T_TMP/a" ] && [ -s "$T_TMP/b" ] && break; sleep 0.1; done
_tier_c_record_pid "$a" "$LOG_DIR/xwayland.pid"
_tier_c_record_pid "$b" "$LOG_DIR/weston.pid"
printf "pid=%s\n" "$(_tier_c_read_pid "$LOG_DIR/xwayland.pid")"
_tier_c_stop "$a" "$b"; rc=$?
printf "stop=%s alive=" "$rc"
_tier_c_alive "$a" && printf a
_tier_c_alive "$b" && printf b
printf "done\n"
mkdir -p /tmp/gs-weston; _tier_c_cleanup
test ! -e "$LOG_DIR/weston.pid" && test ! -d /tmp/gs-weston'
stop_run
assert_rc 0 'clean stop succeeds'
assert_contains "$T_STDOUT" 'stop=0 alive=done' 'both gone without escalation'
assert_match 'SIGTERM to Xwayland .*SIGTERM to weston' "${T_STDOUT//$'\n'/ }" 'ordered signals'
assert_not_contains "$T_STDERR" 'SIGKILL' 'no escalation warning'
assert_no_file "$LOG_DIR/xwayland.pid" 'PID file cleaned'

t_case 'missing or reused recorded PID never signals the process'
STOP_BODY='sleep 600 & a=$!
printf "%s wrong-comm\n" "$a" > "$LOG_DIR/xwayland.pid"
if _tier_c_read_pid "$LOG_DIR/xwayland.pid"; then exit 8; fi
if _tier_c_read_pid "$LOG_DIR/weston.pid"; then exit 9; fi
_tier_c_alive "$a" || exit 10
echo safe'
stop_run
assert_rc 0 'identity mismatch and absent file rejected'
assert_eq safe "$T_STDOUT" 'unrelated live process retained'

for mode in ignoring stopped survivor; do
  t_case "bounded stop: $mode"
  STOP_BODY='bash -c '\''trap "" TERM; echo ready; while :; do sleep 0.1; done'\'' > "$T_TMP/a" & a=$!
for ((i=0;i<30;i++)); do [ -s "$T_TMP/a" ] && break; sleep 0.1; done
if [ "$STOP_MODE" = stopped ]; then builtin kill -STOP "$a"; fi
kill() {
  if [ "$STOP_MODE" = survivor ] && [ "${2:-}" = "$a" ]; then
    case "$1" in -9|-KILL) return 0 ;; esac
  fi
  builtin kill "$@"
}
started=$SECONDS
_tier_c_stop "$a" ""; rc=$?
elapsed=$((SECONDS-started))
printf "stop=%s elapsed=%s\n" "$rc" "$elapsed"
[ "$elapsed" -lt 20 ] || exit 8
if [ "$STOP_MODE" = survivor ]; then
  _tier_c_alive "$a" || exit 9
else
  if _tier_c_alive "$a"; then exit 10; fi
fi'
  stop_run STOP_MODE="$mode"
  assert_rc 0 'stop returns within twenty seconds'
  assert_contains "$T_STDOUT" 'stop=1 elapsed=' 'escalation returns one'
  assert_contains "$T_STDERR" 'ignored SIGTERM, sending SIGKILL' 'escalation is explicit'
  if [ "$mode" = survivor ]; then
    assert_contains "$T_STDERR" 'survived SIGKILL (state ' 'kernel survivor is reported'
  else
    assert_not_contains "$T_STDERR" 'survived SIGKILL' 'process is gone'
  fi
done
t_done
