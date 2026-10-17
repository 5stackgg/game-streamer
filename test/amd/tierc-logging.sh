# S3-U18 exercises this chain after the launcher exits in the separate host test.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

t_case 'raw and tagged display-server logging'
t_run -- 'set -uo pipefail
. "$GS_REPO/src/lib/xorg.sh"
_spawn_logged_to stub "$LOG_DIR/stub.log" bash -c '\''printf "raw-one\nCould not resolve keysym XF86Test\nErrors from xkbcomp are not fatal\nraw-two\n"'\''
wait "$SPAWNED_PID"
for ((i=0; i<20; i++)); do
  grep -q raw-two "$LOG_DIR/stub.log" 2>/dev/null && break
  sleep 0.1
done
sleep 0.1
cat "$LOG_DIR/stub.log"'
assert_rc 0 'server and log readers exit cleanly'
assert_contains "$T_STDOUT" 'Could not resolve keysym XF86Test' 'raw noise is retained'
assert_contains "$T_STDOUT" 'raw-two' 'raw final line'
assert_contains "$T_STDERR" '[stub] raw-one' 'tagged first line'
assert_contains "$T_STDERR" '[stub] raw-two' 'tagged final line'
assert_not_contains "$T_STDERR" 'XF86Test' 'XKB noise filtered only in pod output'
t_done
