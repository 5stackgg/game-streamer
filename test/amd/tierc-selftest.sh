# S3-U10 self-test branch coverage. Every run uses the shipped helper functions.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

selftest_case() {
  t_case "$1"
  t_fake_gpu 0000:c6:00.0 0x1002 0x1586 0x038000 renderD128
  mkdir -p "$GS_SYSFS_ROOT/class/drm/renderD128"
  ln -s "$GS_SYSFS_ROOT/bus/pci/devices/0000:c6:00.0" "$GS_SYSFS_ROOT/class/drm/renderD128/device"
  : > "$LOG_DIR/xwayland.20.log"
  t_stub xdpyinfo 'if [ "${BIG_PROBE:-0}" = 1 ]; then awk '\''BEGIN{for(i=0;i<6000;i++)print "padding extension line"}'\''; fi
case "$*" in
  *-queryExtensions*)
    if [ "${SELF_MODE:-}" = no-dri3 ]; then echo "RANDR"; else echo "DRI3"; fi ;;
  *)
    if [ "${SELF_MODE:-}" = root ]; then echo "dimensions: 1280x720 pixels"; else echo "dimensions: 1920x1080 pixels"; fi ;;
esac'
  t_stub xrandr 'if [ "${SELF_MODE:-}" = mode ]; then echo "1280x720 60.0*"; else echo "1920x1080 60.0*"; fi'
  t_stub vkcube 'case "${SELF_MODE:-}" in
  vk-fail) echo "device lost"; exit 1 ;;
  vk-cpu) echo "Selected GPU: llvmpipe, type: Cpu" ;;
  *) echo "Selected GPU: AMD Radeon (RADV GFX1151), type: IntegratedGpu" ;;
esac'
}

selftest_run() {
  t_run GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:c6:00.0 "$@" -- 'set -uo pipefail
. "$GS_REPO/src/lib/xorg.sh"
export GS_RENDER_NODE=/dev/dri/renderD128
alive_impl=$(declare -f _tier_c_alive)
eval "${alive_impl/_tier_c_alive/_tier_c_real_alive}"
_tier_c_alive() { local GS_PROC_ROOT=/proc; _tier_c_real_alive "$@"; }
sleep 600 & _GS_TIER_WESTON=$!
sleep 600 & _GS_TIER_XW=$!
trap '\''_tier_c_stop "$_GS_TIER_XW" "$_GS_TIER_WESTON" || true'\'' EXIT
_GS_TIER_DISPLAY=:20
for pid in "$_GS_TIER_WESTON" "$_GS_TIER_XW"; do
  mkdir -p "$GS_PROC_ROOT/$pid/fd"
  ln -s "/proc/$pid/comm" "$GS_PROC_ROOT/$pid/comm"
  ln -s "/proc/$pid/stat" "$GS_PROC_ROOT/$pid/stat"
  ln -s /dev/dri/renderD128 "$GS_PROC_ROOT/$pid/fd/3"
done
case "${SELF_MODE:-}" in
  duplicate) ln -s /dev/dri/renderD128 "$GS_PROC_ROOT/$_GS_TIER_XW/fd/4" ;;
  different) rm "$GS_PROC_ROOT/$_GS_TIER_XW/fd/3"; ln -s /dev/dri/renderD129 "$GS_PROC_ROOT/$_GS_TIER_XW/fd/3" ;;
  two) ln -s /dev/dri/renderD129 "$GS_PROC_ROOT/$_GS_TIER_XW/fd/4" ;;
  no-fd) rm "$GS_PROC_ROOT/$_GS_TIER_XW/fd/3" ;;
  unreadable) rm -rf "$GS_PROC_ROOT/$_GS_TIER_XW/fd" ;;
  address) export GS_GPU_PCI_ADDRESS=0000:c7:00.0 ;;
  vendor) echo 0x10de > "$GS_SYSFS_ROOT/bus/pci/devices/0000:c6:00.0/vendor" ;;
  glamor) echo "Failed to initialize glamor" > "$LOG_DIR/xwayland.20.log" ;;
  weston-dead) kill "$_GS_TIER_WESTON"; wait "$_GS_TIER_WESTON" 2>/dev/null || true ;;
  xw-dead) kill "$_GS_TIER_XW"; wait "$_GS_TIER_XW" 2>/dev/null || true ;;
esac
rc=0
_tier_c_selftest || rc=$?
printf "rc=%s reason=%s detail=%s\n" "$rc" "$_GS_TIER_REASON" "$_GS_TIER_DETAIL"'
}

for spec in 'good ok' 'duplicate ok' 'glamor no-dri3' 'no-dri3 no-dri3' \
            'different device-check' 'two device-check' 'address device-check' \
            'vendor device-check' 'no-fd device-check' 'unreadable device-check' \
            'root root-size' 'mode root-size' 'vk-fail vkcube-failed' 'vk-cpu vkcube-failed' \
            'weston-dead weston-failed' 'xw-dead xwayland-failed'; do
  read -r mode expected <<< "$spec"
  selftest_case "self-test: $mode"
  selftest_run SELF_MODE="$mode"
  assert_rc 0 'bounded case completes'
  if [ "$expected" = ok ]; then
    assert_contains "$T_STDOUT" 'rc=0 reason=' 'self-test succeeds'
    assert_eq '--c 60' "$(t_calls vkcube)" 'no forced WSI argument'
  else
    assert_contains "$T_STDOUT" "rc=1 reason=$expected" 'classified stage failure'
    case "$mode" in
      different|two|address|vendor) assert_contains "$T_STDOUT" 'mismatch' 'device mismatch detail' ;;
      no-fd|unreadable) assert_contains "$T_STDOUT" 'unknown' 'unknown device detail' ;;
    esac
  fi
done
t_done
