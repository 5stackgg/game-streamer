# S3-U15: run the actual supervisor loop, not a copied check. Startup/CS2 are
# outside this unit; real shutdown_display and tier C process handling are used.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

supervisor_case() {
  t_case "$1"
  t_stub sleep 'if [ "$1" = 5 ]; then exit 0; fi; exec /usr/bin/sleep "$@"'
  t_stub pkill 'if [ "${2:-}" = Xorg ] && [ -f "$T_TMP/xorg.pid" ]; then
  kill -TERM "$(cat "$T_TMP/xorg.pid")"
fi'
  t_stub pgrep 'if [ "${2:-}" = Xorg ] && [ -f "$T_TMP/xorg.pid" ] && kill -0 "$(cat "$T_TMP/xorg.pid")" 2>/dev/null; then echo "$(cat "$T_TMP/xorg.pid")"; exit 0; fi; exit 1'
  t_stub display-server 'name="$1"
trap "echo $name-TERM >> \"$T_TMP/events\"; exit 0" TERM
touch "$T_TMP/$name.ready"
while :; do /usr/bin/sleep 0.1; done'
  # Exactly the final supervisor loop, including its new counter initialization.
  awk '/^_GS_DISPLAY_FAILURES=0$|^while :; do$/{copy=1} copy{print}' \
    "$GS_REPO/src/flows/run-live.sh" > "$T_TMP/supervisor.sh"
}

supervisor_run() {
  t_run GS_PROC_ROOT=/proc GS_GPU_VENDOR=amd STATUS_DIE_FLUSH_SECONDS=0 "$@" -- 'set -uo pipefail
SCRIPT_TAG=run-live
. "$GS_REPO/src/lib/xorg.sh"
MATCH_ID=match-1
echo "${SUP_TIER:-C} requested" > "$LOG_DIR/display_tier"
pids=()
trap '\''for p in "${pids[@]}"; do builtin kill -KILL "$p" 2>/dev/null || true; done
_tier_c_cleanup'\'' EXIT
if [ "${SUP_TIER:-C}" = C ]; then
  display-server Xwayland & a=$!; pids+=("$a")
  display-server weston & b=$!; pids+=("$b")
  for ((i=0;i<30;i++)); do [ -e "$T_TMP/Xwayland.ready" ] && [ -e "$T_TMP/weston.ready" ] && break; /usr/bin/sleep 0.1; done
  _tier_c_record_pid "$a" "$LOG_DIR/xwayland.pid"
  _tier_c_record_pid "$b" "$LOG_DIR/weston.pid"
else
  display-server Xorg & a=$!; pids+=("$a"); echo "$a" > "$T_TMP/xorg.pid"
  for ((i=0;i<30;i++)); do [ -e "$T_TMP/Xorg.ready" ] && break; /usr/bin/sleep 0.1; done
fi
warn_impl=$(declare -f warn)
eval "${warn_impl/warn/warn_original}"
warn() { printf "WARN:%s\n" "$*" >> "$T_TMP/events"; warn_original "$@"; }
report_status() { printf "REPORT:%s\n" "$*" >> "$T_TMP/events"; }
kill_steam() { echo kill-steam >> "$T_TMP/events"; }
stream_running() {
  local n=0
  [ ! -f "$T_TMP/pass" ] || read -r n < "$T_TMP/pass"
  n=$((n+1)); echo "$n" > "$T_TMP/pass"
  [ "$n" -le 6 ] || exit 0
  [ "${SUP_MODE:-}" = stream-up ]
}
xorg_running() {
  local n=0
  [ ! -f "$T_TMP/check" ] || read -r n < "$T_TMP/check"
  n=$((n+1)); echo "$n" > "$T_TMP/check"
  echo display-check >> "$T_TMP/events"
  if [ "${SUP_MODE:-}" = recover ]; then case "$n" in 3|6) return 0 ;; esac; fi
  return 1
}
restart_capture() { echo restart >> "$T_TMP/events"; }
kill() {
  if [ "${SUP_MODE:-}" = term ] && [ "${1:-}" = -TERM ] && [ ! -e "$T_TMP/term-sent" ]; then
    touch "$T_TMP/term-sent"
    bash -c "sleep 0.1; kill -TERM $$" &
  fi
  builtin kill "$@"
}
# The production TERM trap itself is kept byte-identical.
trap_line=""; traps=0
while IFS= read -r line; do
  case "$line" in
    trap*"shutdown_display; exit 143"*TERM) trap_line="$line"; traps=$((traps+1)) ;;
  esac
done < "$GS_REPO/src/flows/run-live.sh"
[ "$traps" = 1 ] || exit 12
eval "$trap_line"
. "$T_TMP/supervisor.sh"'
}

for tier in C A; do
  supervisor_case "three display failures on tier $tier"
  supervisor_run SUP_TIER="$tier" SUP_MODE=lost
  assert_rc 1 'display loss ends the pod'
  events=$(cat "$T_TMP/events")
  assert_eq 3 "$(grep -c display-check <<< "$events")" 'three failed checks'
  assert_not_contains "$events" restart 'no restart against a failed display'
  assert_match 'WARN:display lost.*REPORT:status=errored.*kill-steam' "${events//$'\n'/ }" 'warn and report precede shutdown'
  if [ "$tier" = C ]; then
    assert_match 'kill-steam.*Xwayland-TERM.*weston-TERM' "${events//$'\n'/ }" 'actual servers stop in order'
    assert_contains "$T_STDERR" weston.log 'tier C logs named'
  else
    assert_contains "$events" Xorg-TERM 'tier A server stopped'
    assert_contains "$T_STDERR" /var/log/Xorg.20.log 'tier A log named'
  fi
  assert_contains "$T_STDERR" 'ERROR: display lost' 'explicit error follows shutdown'
done

supervisor_case 'a successful check resets consecutive display failures'
supervisor_run SUP_MODE=recover
assert_rc 0 'recovery avoids a false pod failure'
assert_eq 6 "$(cat "$T_TMP/check")" 'six display probes'
assert_eq 2 "$(grep -c '^restart$' "$T_TMP/events")" 'restart only after the two successful probes'
assert_not_contains "$T_STDERR" 'display lost' 'counter reset twice'

supervisor_case 'NVIDIA retains its old capture restart loop'
supervisor_run GS_GPU_VENDOR=nvidia SUP_MODE=lost
assert_rc 0 'legacy loop runs to the bounded fixture end'
assert_no_file "$T_TMP/check" 'no NVIDIA display probe'
assert_eq 6 "$(grep -c '^restart$' "$T_TMP/events")" 'legacy restart count'

supervisor_case 'a running capture takes no display probe or restart path'
supervisor_run SUP_MODE=stream-up
assert_rc 0 'stream-up path completes'
assert_no_file "$T_TMP/check" 'no display check while capture is up'
assert_not_contains "$(cat "$T_TMP/events" 2>/dev/null || true)" restart 'no restart while capture is up'

supervisor_case 'TERM during ordered display-loss shutdown uses the existing trap'
started=$SECONDS
supervisor_run SUP_MODE=term
assert_rc 143 'TERM exits through its existing trap'
assert_match '^([0-9]|1[0-9])$' "$((SECONDS-started))" 'TERM shutdown stays below twenty seconds'
events=$(cat "$T_TMP/events")
assert_contains "$events" Xwayland-TERM 'Xwayland exits'
assert_contains "$events" weston-TERM 'weston exits'
t_done
