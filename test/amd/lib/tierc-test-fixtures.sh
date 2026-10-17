# shellcheck shell=bash
# shellcheck disable=SC2016  # fixture bodies expand in child shells
# Shared real-helper fixtures for the timing and large-output checks.
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
  t_run GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:c6:00.0 "$@" -- 'set -euo pipefail
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
if [ "${SELF_LOOPS:-1}" -gt 1 ]; then
  for ((iteration=1;iteration<=SELF_LOOPS;iteration++)); do
    _GS_TIER_REASON=""; rc=0
    _tier_c_selftest || rc=$?
    if [ "$rc" != "${SELF_EXPECT_RC:-0}" ] || [ "$_GS_TIER_REASON" != "${SELF_EXPECT_REASON:-}" ]; then
      printf "failed iteration=%s rc=%s reason=%s\n" "$iteration" "$rc" "$_GS_TIER_REASON"; exit 14
    fi
  done
  printf "loops=%s passed\n" "$SELF_LOOPS"
else
  probe_started=$SECONDS
  _tier_c_selftest || rc=$?
  printf "probe-elapsed=%s\n" "$((SECONDS-probe_started))"
fi
printf "rc=%s reason=%s detail=%s\n" "$rc" "$_GS_TIER_REASON" "$_GS_TIER_DETAIL"'
}


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
