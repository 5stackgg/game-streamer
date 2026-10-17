# S3-U7 start_xorg integration and S3-U12 tier C liveness/stop.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

start_case() {
  t_case "$1"
  t_stub pgrep 'exit 1'
  t_stub xhost
  t_stub xprop
}

start_run() {
  t_run "$@" -- 'set -uo pipefail
. "$GS_REPO/src/lib/xorg.sh"
if [ "${USE_C_DEFAULT:-0}" = 1 ]; then _GS_DISPLAY_TIER_DEFAULT=C; fi
printf "C stale\n" > "$LOG_DIR/display_tier"
if [ "${GS_GPU_VENDOR:-}" != amd ]; then rm "$LOG_DIR/display_tier"; fi
xorg_running() { return 1; }
_wait_for_foreign_streamer_x() { return 0; }
enable_gpu_persistence() { return 0; }
spawn_logged() { return 0; }
_xorg_wsi_probe() { return 0; }
_xorg_try_displays() { echo A >> "$T_TMP/paths"; XORG_FOUND=:20; return 0; }
_start_tier_c() {
  echo C >> "$T_TMP/paths"
  case "${START_C_MODE:-good}" in
    good) printf "%s\n" "$_GS_TIER_PICK" > "$LOG_DIR/display_tier"; XORG_FOUND=:21; return 0 ;;
    reason) echo "A fallback:stub" > "$LOG_DIR/display_tier"; return 1 ;;
    unwritten) return 1 ;;
  esac
}
start_xorg
printf "tier=<%s> display=%s paths=<%s>\n" \
  "$(cat "$LOG_DIR/display_tier" 2>/dev/null)" "$DISPLAY" "$(tr "\n" , < "$T_TMP/paths")"'
}

for vendor in nvidia ''; do
  start_case "non-AMD vendor <$vendor> ignores C"
  start_run GS_GPU_VENDOR="$vendor" GS_DISPLAY_TIER=C
  assert_rc 0 'fresh start succeeds under set -u'
  assert_contains "$T_STDOUT" 'tier=<> display=:20 paths=<A,>' 'only legacy walk'
  assert_not_contains "$T_STDERR" 'unbound variable' 'no unset tier failure'
done

for spec in 'default A default' 'A A requested' 'C C requested' 'defaultC C default' \
            'reason A fallback:stub' 'unwritten A fallback:unknown' 'forced A forced:MESA_VK_WSI_DEBUG'; do
  read -r mode tier how <<< "$spec"
  start_case "AMD integration: $mode"
  envs=(GS_GPU_VENDOR=amd)
  case "$mode" in
    default) : ;;
    defaultC) envs+=(USE_C_DEFAULT=1) ;;
    reason|unwritten) envs+=(GS_DISPLAY_TIER=C START_C_MODE="$mode") ;;
    forced) envs+=(GS_DISPLAY_TIER=C MESA_VK_WSI_DEBUG=sw) ;;
    *) envs+=(GS_DISPLAY_TIER="$mode") ;;
  esac
  start_run "${envs[@]}"
  assert_rc 0 'start succeeds with a safe tier outcome'
  assert_contains "$T_STDOUT" "tier=<$tier $how>" 'exact outcome replaces stale file'
  if [ "$tier" = C ]; then
    assert_contains "$T_STDOUT" 'display=:21 paths=<C,>' 'C is never relabeled A'
  else
    assert_contains "$T_STDOUT" 'display=:20' 'tier A starts from the base'
  fi
  if [ "$mode" = unwritten ]; then
    assert_eq 1 "$(grep -c 'tier C returned without a fallback line' <<< "$T_STDERR")" 'missing fallback is explicit'
  fi
done

live_case() {
  t_case "$1"
  t_stub pkill
  t_stub pgrep 'exit 1'
  t_stub xdpyinfo 'if [ "${LIVE_MODE:-}" = silent ]; then sleep 600; fi'
}

live_run() {
  t_run GS_GPU_VENDOR=amd GS_PROC_ROOT=/proc "$@" -- 'set -uo pipefail
. "$GS_REPO/src/lib/xorg.sh"
echo "C requested" > "$LOG_DIR/display_tier"
sleep 600 & a=$!; sleep 600 & b=$!
sleep 0.1
trap '\''builtin kill -KILL "$a" "$b" 2>/dev/null || true; _tier_c_cleanup'\'' EXIT
_tier_c_record_pid "$a" "$LOG_DIR/xwayland.pid"
_tier_c_record_pid "$b" "$LOG_DIR/weston.pid"
case "${LIVE_MODE:-}" in
  xw-dead) kill "$a"; wait "$a" 2>/dev/null || true ;;
  weston-dead) kill "$b"; wait "$b" 2>/dev/null || true ;;
  reused) printf "%s wrong-comm\n" "$a" > "$LOG_DIR/xwayland.pid" ;;
  missing) rm "$LOG_DIR/xwayland.pid" ;;
  stubborn)
    kill() {
      if [ "${1:-}" = -TERM ] && [ "${2:-}" = "$a" ]; then return 0; fi
      builtin kill "$@"
    }
    ;;
esac
rc=0
xorg_running || rc=$?
printf "running=%s\n" "$rc"
if [ "${LIVE_MODE:-}" = silent ]; then start_xorg; exit 9; fi
stoprc=0
stop_xorg || stoprc=$?
printf "stop=%s tier=%s\n" "$stoprc" "$(cat "$LOG_DIR/display_tier")"
if [ "${LIVE_MODE:-}" = reused ]; then _tier_c_alive "$a" || exit 8; fi'
}

for mode in good xw-dead weston-dead reused missing stubborn; do
  live_case "liveness: $mode"
  live_run LIVE_MODE="$mode"
  assert_rc 0 'stop completes safely'
  if [ "$mode" = good ] || [ "$mode" = stubborn ]; then expected=0; else expected=1; fi
  assert_contains "$T_STDOUT" "running=$expected" 'recorded identities decide liveness'
  if [ "$mode" = stubborn ]; then
    assert_contains "$T_STDOUT" 'stop=1 tier=C requested' 'escalated stop result is preserved'
    assert_contains "$T_STDERR" 'ignored SIGTERM, sending SIGKILL' 'actual stop_xorg escalation'
  else
    assert_contains "$T_STDOUT" 'stop=0 tier=C requested' 'stop retains outcome'
  fi
  assert_eq '' "$(t_calls pgrep)" 'tier C never searches by process name'
  assert_eq '-x openbox' "$(t_calls pkill)" 'only openbox is stopped by name'
done

live_case 'a silent recorded tier C server takes the wedge branch'
live_run LIVE_MODE=silent
assert_rc 1 'wedge fails instead of starting another server'
assert_contains "$T_STDERR" 'tier C is unresponsive or incomplete' 'generic wedge diagnostic'
assert_contains "$T_STDERR" 'weston.log' 'weston log named'
assert_contains "$T_STDERR" 'xwayland.20.log' 'Xwayland log named'
t_done
