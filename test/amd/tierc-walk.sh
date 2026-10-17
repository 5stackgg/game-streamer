# S3-U8/U9: real child processes, temporary proc socket rows and recording tools.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

walk_case() {
  t_case "$1"
  mkdir -p "$GS_PROC_ROOT/net"
  : > "$GS_PROC_ROOT/net/unix"
  t_stub xdpyinfo 'n="${2#:}"
if [ "${WALK_MODE:-}" = busy ]; then exit 0; fi
if [ "${WALK_MODE:-}" = answering ] && [ "$n" = 20 ]; then exit 0; fi
[ -e "$T_TMP/up.$n" ]'
  t_stub Xwayland 'n="${1#:}"; mode="${WALK_MODE:-good}"
printf -v argv "%q " "$@"
printf "%s\n" "${argv% }" > "$T_TMP/xw-argv.$n"
printf "WAYLAND_DISPLAY=<%s> WAYLAND_SOCKET=<%s> XDG_RUNTIME_DIR=<%s>\n" \
  "${WAYLAND_DISPLAY-}" "${WAYLAND_SOCKET-}" "$XDG_RUNTIME_DIR" > "$T_TMP/xw-env.$n"
if [ "$n" = 20 ]; then
  case "$mode" in
    listen|delayed) echo "Cannot establish any listening sockets"; exit 1 ;;
    badexit) echo "Unrecognized option: invalid"; exit 1 ;;
    giveup) echo "xwl_give_up: compositor unavailable"; exit 1 ;;
    signal) kill -TERM $$ ;;
    silent) trap "exit 0" TERM; while :; do sleep 0.1; done ;;
  esac
fi
mkdir -p "$GS_PROC_ROOT/$$/fd"
ln -s "/proc/$$/comm" "$GS_PROC_ROOT/$$/comm"
ln -s "/proc/$$/stat" "$GS_PROC_ROOT/$$/stat"
printf "%s\n" "$$" > "/tmp/.X$n-lock"
if [ "$n" = 20 ] && [ "$mode" = wrong-lock ]; then echo 999999 > "/tmp/.X$n-lock"; fi
inode=$((80000+n)); held="$inode"
if [ "$n" = 20 ] && [ "$mode" = foreign-listener ]; then held=99999; fi
ln -s "socket:[$held]" "$GS_PROC_ROOT/$$/fd/3"
printf "000: 1 0 00000000 0001 03 70001 @/tmp/.X11-unix/X%s\n" "$n" >> "$GS_PROC_ROOT/net/unix"
printf "000: 1 0 00000000 0001 03 70002 @/tmp/.X11-unix/X%s\n" "$n" >> "$GS_PROC_ROOT/net/unix"
if [ "$n" != 20 ] || [ "$mode" != accepted-only ]; then
  printf "000: 1 0 00010000 0001 01 %s @/tmp/.X11-unix/X%s\n" "$inode" "$n" >> "$GS_PROC_ROOT/net/unix"
fi
trap '\''rm -f "/tmp/.X$n-lock" "$T_TMP/up.$n"; exit 0'\'' TERM
touch "$T_TMP/up.$n"
echo "Xwayland ready"
while :; do sleep 0.1; done'
}

walk_run() {
  t_run GS_GPU_VENDOR=amd "$@" -- 'set -uo pipefail
. "$GS_REPO/src/lib/xorg.sh"
export DISPLAY=:20
# Socket/fd metadata is a fixture; liveness uses the real child process table.
alive_impl=$(declare -f _tier_c_alive)
eval "${alive_impl/_tier_c_alive/_tier_c_real_alive}"
_tier_c_alive() { local GS_PROC_ROOT=/proc; _tier_c_real_alive "$@"; }
trap '\''_tier_c_stop "${_GS_TIER_XW:-}" "" || true
[ -z "${held:-}" ] || kill "$held" 2>/dev/null || true
rm -f /tmp/.X2{0..9}-lock'\'' EXIT
if [ "${WALK_MODE:-}" = stale ]; then
  echo 999999 > /tmp/.X20-lock; mkdir -p /tmp/.X11-unix; touch /tmp/.X11-unix/X20
elif [ "${WALK_MODE:-}" = live-lock ]; then
  sleep 600 & held=$!; echo "$held" > /tmp/.X20-lock
elif [ "${WALK_MODE:-}" = bound ]; then
  echo "000: 1 0 00010000 0001 01 88888 @/tmp/.X11-unix/X20" > "$GS_PROC_ROOT/net/unix"
fi
started=$SECONDS
_tier_c_try_displays; rc=$?
printf "rc=%s reason=%s detail=%s display=%s original=%s elapsed=%s\n" "$rc" "$_GS_TIER_REASON" "$_GS_TIER_DETAIL" "$_GS_TIER_DISPLAY" "$DISPLAY" "$((SECONDS-started))"'
}

for mode in good stale answering live-lock bound wrong-lock foreign-listener accepted-only listen delayed; do
  walk_case "walk: $mode"
  if [ "$mode" = delayed ]; then t_stub tee 'sleep 0.7; exec /usr/bin/tee "$@"'; fi
  walk_run WALK_MODE="$mode" WAYLAND_SOCKET=77 WAYLAND_DISPLAY=foreign
  assert_rc 0 'bounded walker and cleanup complete'
  case "$mode" in good|stale) expected=:20 ;; *) expected=:21 ;; esac
  assert_contains "$T_STDOUT" "rc=0 reason=" 'walk found a display'
  assert_contains "$T_STDOUT" "display=$expected original=:20" 'only candidate global changes'
  calls=$(cat "$T_TMP"/xw-argv.* 2>/dev/null || true)
  assert_contains "$calls" "$expected -geometry 1920x1080 -noreset -nolisten tcp -listen unix -s 0 -fakescreenfps 60 -verbose 3" 'exact rootful argv'
  assert_contains "$(cat "$T_TMP/xw-env.${expected#:}")" 'WAYLAND_DISPLAY=</tmp/gs-weston/gs-weston> WAYLAND_SOCKET=<>' 'private absolute Wayland socket and no inherited fd'
  assert_contains "$(cat "$T_TMP/xw-env.${expected#:}")" "XDG_RUNTIME_DIR=<$T_TMP/xdg>" 'pod runtime preserved for Xwayland'
  case "$mode" in
    answering|live-lock|bound) assert_not_contains "$calls" ':20 ' 'held display never spawned' ;;
    wrong-lock|foreign-listener|accepted-only) assert_contains "$T_STDOUT" 'ownership mismatch on :20' 'owned listener required' ;;
  esac
done

for mode in badexit giveup signal silent busy; do
  walk_case "failure: $mode"
  walk_run WALK_MODE="$mode"
  assert_rc 0 'bounded error wrapper completes'
  if [ "$mode" = busy ]; then
    assert_contains "$T_STDOUT" 'reason=no-free-display' 'all held displays'
    assert_eq '' "$(cat "$T_TMP"/xw-argv.* 2>/dev/null || true)" 'no spawn on any held display'
  else
    assert_contains "$T_STDOUT" 'rc=1 reason=xwayland-failed' 'failed startup reason'
    case "$mode" in
      badexit|giveup) assert_contains "$T_STDOUT" 'detail=exit 1:' 'exit and last line' ;;
      signal) assert_contains "$T_STDOUT" 'detail=signal 15:' 'signal detail' ;;
      silent) assert_contains "$T_STDOUT" 'timeout waiting 10s' 'bounded silent startup' ;;
    esac
  fi
done
t_done
