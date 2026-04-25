#!/usr/bin/env bash
# Headless X server + lightweight WM. Idempotent.

start_openbox() {
  if pgrep -x openbox >/dev/null 2>&1; then return 0; fi
  command -v openbox >/dev/null 2>&1 || return 0
  DISPLAY="$DISPLAY" nohup openbox >/tmp/openbox.log 2>&1 &
  sleep 1
  log "openbox started"
}

start_xorg() {
  if pgrep -x Xorg >/dev/null 2>&1; then
    log "Xorg already running on $DISPLAY"
    start_openbox
    open_xhost
    return 0
  fi

  local n="${DISPLAY#:}"
  rm -f "/tmp/.X${n}-lock" "/tmp/.X11-unix/X${n}" 2>/dev/null || true

  log "starting Xorg on $DISPLAY"
  # -listen unix forces creation of the filesystem socket at
  # /tmp/.X11-unix/X0. CS2's bundled libX11 only checks that path.
  # -config must be a bare filename (no path) when Xorg is setuid via
  # Xorg.wrap; it auto-searches /etc/X11/.
  Xorg "$DISPLAY" -config xorg-dummy.conf \
    -noreset -nolisten tcp -listen unix vt7 >/tmp/xorg.log 2>&1 &
  echo $! >/tmp/xorg.pid

  for _ in $(seq 1 30); do
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
      log "Xorg up on $DISPLAY"
      open_xhost
      start_openbox
      return 0
    fi
    sleep 0.5
  done

  log "ERROR: Xorg did not come up — last 80 lines of /tmp/xorg.log:"
  tail -n 80 /tmp/xorg.log >&2 || true
  return 1
}

open_xhost() {
  # Steam runs in a sandboxed pressure-vessel — without xhost permission
  # for local connections it segfaults on "Unable to open display".
  xhost +local: >/dev/null 2>&1 || true
  xhost +SI:localuser:root >/dev/null 2>&1 || true
}
