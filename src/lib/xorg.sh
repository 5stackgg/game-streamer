# shellcheck shell=bash
# Bring up Xorg + openbox and open access for the local root user.
# All ops are idempotent.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

xorg_running() {
  pgrep -x Xorg >/dev/null 2>&1 && xdpyinfo -display "$DISPLAY" >/dev/null 2>&1
}

start_xorg() {
  if xorg_running; then
    log "xorg already up on $DISPLAY"
  else
    log "starting Xorg on $DISPLAY (config: $XORG_CONFIG, log: $LOG_DIR/xorg.log)"
    local n="${DISPLAY#:}"
    rm -f "/tmp/.X${n}-lock" "/tmp/.X11-unix/X${n}" 2>/dev/null || true
    # NOTE: -config takes a BARE filename here. Xorg.wrap (the setuid
    # wrapper) refuses absolute paths for security, leaving Xorg with no
    # Device/Screen → "no screens found".
    local cmd=(Xorg "$DISPLAY" -config "$XORG_CONFIG" -noreset
               -nolisten tcp -listen unix vt7)
    log "  exec: ${cmd[*]}"
    nohup "${cmd[@]}" >"$LOG_DIR/xorg.log" 2>&1 &
    local xpid=$!
    log "  Xorg pid=$xpid — waiting up to 10s for display"
    local i
    for i in $(seq 1 20); do
      xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
      if ! kill -0 "$xpid" 2>/dev/null; then
        warn "Xorg died (pid $xpid)"
        dump_log "$LOG_DIR/xorg.log"
        die "Xorg failed to start"
      fi
      sleep 0.5
    done
    if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
      warn "Xorg never accepted clients on $DISPLAY"
      dump_log "$LOG_DIR/xorg.log"
      die "Xorg failed to start"
    fi
    log "  Xorg ready on $DISPLAY"
  fi

  if ! pgrep -x openbox >/dev/null 2>&1; then
    log "starting openbox (log: $LOG_DIR/openbox.log)"
    nohup openbox >"$LOG_DIR/openbox.log" 2>&1 &
    sleep 1
    pgrep -x openbox >/dev/null 2>&1 \
      || { warn "openbox didn't start"; dump_log "$LOG_DIR/openbox.log"; }
  fi

  # Open X access so processes spawned outside our pgid can connect.
  log "opening X access for local users"
  xhost +local:           >/dev/null 2>&1 || true
  xhost +SI:localuser:root >/dev/null 2>&1 || true
}

stop_xorg() {
  pkill -x openbox 2>/dev/null || true
  pkill -x Xorg    2>/dev/null || true
}
