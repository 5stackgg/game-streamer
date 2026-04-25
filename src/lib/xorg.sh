# shellcheck shell=bash
# Bring up Xorg + openbox and open access for the local root user.
# All ops are idempotent.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${XORG_CONFIG:=$SRC_DIR/../xorg-dummy.conf}"

xorg_running() {
  pgrep -x Xorg >/dev/null 2>&1 && xdpyinfo -display "$DISPLAY" >/dev/null 2>&1
}

start_xorg() {
  if xorg_running; then
    log "xorg already up on $DISPLAY"
  else
    log "starting Xorg on $DISPLAY"
    local n="${DISPLAY#:}"
    rm -f "/tmp/.X${n}-lock" "/tmp/.X11-unix/X${n}" 2>/dev/null || true
    nohup Xorg "$DISPLAY" -config "$XORG_CONFIG" -noreset \
      -nolisten tcp -listen unix vt7 \
      >"$LOG_DIR/xorg.log" 2>&1 &
    local i
    for i in $(seq 1 20); do
      xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
      sleep 0.5
    done
    xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 \
      || die "Xorg did not come up — see $LOG_DIR/xorg.log"
  fi

  if ! pgrep -x openbox >/dev/null 2>&1; then
    log "starting openbox"
    nohup openbox >"$LOG_DIR/openbox.log" 2>&1 &
    sleep 1
  fi

  # Open X access so processes spawned outside our pgid can connect.
  xhost +local:           >/dev/null 2>&1 || true
  xhost +SI:localuser:root >/dev/null 2>&1 || true
}

stop_xorg() {
  pkill -x openbox 2>/dev/null || true
  pkill -x Xorg    2>/dev/null || true
}
