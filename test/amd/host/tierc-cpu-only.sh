#!/usr/bin/env bash
# S3-I2 CPU-only half. Run after the approved full streamer image build.
set -euo pipefail
: "${AMD_GS_IMAGE:?set the digest of the full candidate streamer image}"
for mode in absent placeholder; do
  docker run --rm --init --platform linux/amd64 --entrypoint bash \
    -e GS_GPU_VENDOR=amd -e GS_GPU_PCI_ADDRESS=0000:c6:00.0 \
    -e GS_DISPLAY_TIER=C -e NVIDIA_VISIBLE_DEVICES=void -e TEST_MODE="$mode" \
    "$AMD_GS_IMAGE" -c 'set -euo pipefail
LOG_DIR=$(mktemp -d /tmp/tierc-i2.XXXXXX)
GS_SYSFS_ROOT="$LOG_DIR/sys"
export LOG_DIR GS_SYSFS_ROOT
mkdir -p "$GS_SYSFS_ROOT"
if [ "$TEST_MODE" = placeholder ]; then
  dev="$GS_SYSFS_ROOT/bus/pci/devices/0000:c6:00.0"
  mkdir -p "$dev/drm/renderD128" /dev/dri
  printf "0x1002\n" > "$dev/vendor"
  printf "0x1586\n" > "$dev/device"
  printf "0x038000\n" > "$dev/class"
  touch /dev/dri/renderD128
fi
. /opt/game-streamer/src/lib/xorg.sh
trap '\''stop_xorg || true'\'' EXIT
start_xorg
line=$(cat "$LOG_DIR/display_tier")
if [ "$TEST_MODE" = absent ]; then
  test "$line" = "A fallback:no-render-node"
  test ! -e "$LOG_DIR/weston.log"
else
  case "$line" in
    "A fallback:weston-renderer"|"A fallback:weston-failed") ;;
    *) printf "unexpected result: %s\n" "$line" >&2; exit 1 ;;
  esac
fi
test "$DISPLAY" = :20
test "$(cat "$LOG_DIR/wsi_mode")" = sw
test ! -e /tmp/gs-weston
test ! -e "$LOG_DIR/weston.pid"
test ! -e "$LOG_DIR/xwayland.pid"
! pgrep -x weston
! pgrep -x Xwayland
out=$(timeout 5 xprop -display "$DISPLAY" -root _GS_STREAMER)
grep -q _GS_STREAMER <<< "$out"
printf "S3-I2 %s: %s, coexist=%s wsi=sw\n" "$TEST_MODE" "$line" "$DISPLAY"
'
done
