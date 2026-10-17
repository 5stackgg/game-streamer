# S3-U8 weston arguments and S3-U17 delayed renderer checks.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

weston_case() {
  t_case "$1"
  t_stub weston 'printf "DISPLAY=<%s> WAYLAND_DISPLAY=<%s> WAYLAND_SOCKET=<%s> XDG_RUNTIME_DIR=<%s>\n" \
    "${DISPLAY-}" "${WAYLAND_DISPLAY-}" "${WAYLAND_SOCKET-}" "$XDG_RUNTIME_DIR"
touch "$XDG_RUNTIME_DIR/gs-weston"
sleep "${RENDERER_DELAY:-0}"
case "${WESTON_MODE:-good}" in
  good) echo "GL renderer: AMD Radeon (radeonsi, gfx1151)" ;;
  software) echo "GL renderer: llvmpipe" ;;
  absent) : ;;
esac
case "${WESTON_DEVICE:-good}" in
  good) echo "Using rendering device: /dev/dri/renderD128" ;;
  mismatch) echo "Using rendering device: /dev/dri/renderD129" ;;
  unknown) echo "warning: failed to query rendering device from EGL" ;;
  absent) : ;;
esac
trap "exit 0" TERM
while :; do sleep 0.1; done'
}

weston_run() {
  t_run GS_PROC_ROOT=/proc GS_GPU_VENDOR=amd GS_RENDER_NODE=/dev/dri/renderD128 \
    DISPLAY=:99 WAYLAND_DISPLAY=foreign WAYLAND_SOCKET=77 "$@" -- 'set -uo pipefail
. "$GS_REPO/src/lib/xorg.sh"
export GS_RENDER_NODE=/dev/dri/renderD128
export DISPLAY=:99
trap '\''_tier_c_stop "" "${_GS_TIER_WESTON:-}" || true; _tier_c_cleanup'\'' EXIT
started=$SECONDS
_tier_c_start_weston; rc=$?
printf "rc=%s reason=%s detail=%s elapsed=%s\n" "$rc" "$_GS_TIER_REASON" "$_GS_TIER_DETAIL" "$((SECONDS-started))"
stat -c "mode=%a" /tmp/gs-weston
printf "parent-display=%s parent-wayland=%s parent-runtime=%s\n" "$DISPLAY" "$WAYLAND_DISPLAY" "$XDG_RUNTIME_DIR"'
}

weston_case 'weston gets its exact private environment and required flags'
weston_run
assert_rc 0 'wrapper and cleanup succeed'
assert_contains "$T_STDOUT" 'rc=0 reason=' 'renderer and device checks pass'
assert_contains "$(cat "$LOG_DIR/weston.log")" 'DISPLAY=<> WAYLAND_DISPLAY=<> WAYLAND_SOCKET=<> XDG_RUNTIME_DIR=</tmp/gs-weston>' 'clean child environment'
assert_contains "$T_STDOUT" mode=700 'private directory permissions'
assert_contains "$T_STDOUT" 'parent-display=:99 parent-wayland=foreign' 'parent variables retained'
calls=$(t_calls weston)
assert_eq '--backend=headless --renderer=gl --shell=kiosk --no-config --idle-time=0 --width=1920 --height=1080 --socket=gs-weston' "$calls" 'exact argument vector'
assert_no_file /tmp/gs-weston 'cleanup removes private runtime'

for spec in 'software good weston-renderer' 'absent good weston-renderer' \
            'good mismatch device-check' 'good unknown device-check' 'good absent ok'; do
  read -r mode device reason <<< "$spec"
  weston_case "renderer=$mode device=$device"
  weston_run WESTON_MODE="$mode" WESTON_DEVICE="$device"
  assert_rc 0 'bounded wrapper exits'
  if [ "$reason" = ok ]; then
    assert_contains "$T_STDOUT" 'rc=0 reason=' 'fd scan will decide when device line absent'
  else
    assert_contains "$T_STDOUT" "rc=1 reason=$reason" 'stage reason'
  fi
done

for delay in 1 7; do
  weston_case "renderer arrives after ${delay}s"
  weston_run RENDERER_DELAY="$delay"
  assert_rc 0 'bounded delayed check'
  if [ "$delay" = 1 ]; then
    assert_contains "$T_STDOUT" 'rc=0 reason=' 'late line is read in place'
  else
    assert_contains "$T_STDOUT" 'reason=weston-renderer detail=no GL renderer line within 5s' 'too-late line rejected'
    assert_match 'elapsed=[56]($|[^0-9])' "$T_STDOUT" 'five to six second renderer bound'
  fi
done
t_done
