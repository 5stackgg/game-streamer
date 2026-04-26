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

# Dump every named top-level X window (one per line). Cheap; safe to call
# every poll iteration. Useful for figuring out which Steam dialog is
# currently blocking — Steam's CEF dialogs (e.g. "Cloud Out of Date")
# don't have X11 titles, but the Steam window itself does, and its
# "wm class" / state will show whether it's modal.
list_x_windows() {
  if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
    log "  (no display on $DISPLAY)"
    return
  fi
  local count=0
  while IFS= read -r line; do
    log "  $line"
    count=$((count + 1))
  done < <(
    xwininfo -display "$DISPLAY" -root -tree 2>/dev/null \
      | awk '/"[^"]+"/{ for (i=1;i<=NF;i++) if ($i ~ /"[^"]+"/) { print; break } }' \
      | head -25
  )
  [ "$count" = 0 ] && log "  (no named windows)"
}

# Find the main Steam UI window — the largest "Steam"-named window
# at least 500x300. Multiple X11 windows are named "Steam" (a 48x48
# tray icon, 64x24 helper bars, and the real 1280x800 client).
#
# Parses xwininfo -tree output rather than using xdotool: the real
# Steam window is a child window in the X tree (deeper indentation in
# xwininfo) and xdotool's getwindowgeometry doesn't reliably resolve
# size for that case here. xwininfo prints WxH+X+Y for every window
# regardless of nesting, so it's the more direct source.
find_main_steam_window() {
  xwininfo -display "$DISPLAY" -root -tree 2>/dev/null | awk '
    /"Steam":/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+x[0-9]+\+/) {
          split($i, dim, "x")
          w = dim[1]
          sub(/\+.*/, "", dim[2])
          h = dim[2]
          if (w >= 500 && h >= 300) {
            area = w * h
            if (area > best) { best = area; best_id = $1 }
          }
          break
        }
      }
    }
    END { if (best_id != "") print best_id }
  '
}

# Window dimensions for an id. Echoes "WIDTH HEIGHT" or nothing.
_window_size() {
  xwininfo -display "$DISPLAY" -id "$1" 2>/dev/null | awk '
    /^  Width:/  { w = $2 }
    /^  Height:/ { h = $2 }
    END { if (w && h) print w, h }
  '
}

# Absolute screen geometry for an id. Echoes "X Y WIDTH HEIGHT".
_window_geom_abs() {
  xwininfo -display "$DISPLAY" -id "$1" 2>/dev/null | awk '
    /Absolute upper-left X:/ { x = $4 }
    /Absolute upper-left Y:/ { y = $4 }
    /^  Width:/  { w = $2 }
    /^  Height:/ { h = $2 }
    END { if (w && h) print x, y, w, h }
  '
}

# Wait until the main Steam window is on screen — i.e. login is fully
# complete and the UI is rendered. This is a stronger "Steam is ready"
# signal than the IPC pipe alone (the pipe comes up before the UI does,
# and `-applaunch` issued before the UI renders sometimes hangs).
wait_for_main_steam_window() {
  local timeout="${1:-300}"
  log "waiting up to ${timeout}s for the main Steam window (login + UI render)"
  local i id
  for i in $(seq 1 "$timeout"); do
    id=$(find_main_steam_window)
    if [ -n "$id" ]; then
      log "  main Steam window after ${i}s: $id"
      return 0
    fi
    if [ $(( i % 15 )) -eq 0 ]; then
      log "  still waiting (${i}s) — current windows:"
      list_x_windows
      # Also report whether the webhelper that draws the UI is running.
      local wh
      wh=$(pgrep -af 'steamwebhelper' | head -1 || true)
      log "  steamwebhelper: ${wh:-NOT RUNNING}"
    fi
    sleep 1
  done
  warn "main Steam window never appeared after ${timeout}s"
  warn "running full debug dump (also saved to $LOG_DIR/debug-*.txt)"
  if command -v print_full_debug >/dev/null 2>&1; then
    local out="$LOG_DIR/debug-$(date +%Y%m%d-%H%M%S).txt"
    print_full_debug 2>&1 | tee "$out" >&2
    log "saved to $out"
  fi
  return 1
}

# Minimize/hide Steam's main UI + Friends List so they don't sit
# behind whatever dialog cs2 is on. Missed clicks on the shader-skip
# / cloud-out-of-date dialogs were falling through and hitting Steam
# UI buttons (cancelling the launch, opening unrelated panels). Once
# cs2 is up we no longer need Steam visible — the only thing on
# screen we want to interact with is the cs2 window and any modal
# dialogs Steam pops on top.
minimize_steam_windows() {
  local main_id friends_id id count=0
  main_id=$(find_main_steam_window)
  friends_id=$(xdotool search --name '^Friends List$' 2>/dev/null | head -1)
  for id in $main_id $friends_id; do
    [ -z "$id" ] && continue
    log "  hiding $id"
    # Try every method we have. Some are no-ops depending on the WM /
    # window state, so do them all in sequence. Last-resort: move
    # off-screen so even if the window is mapped, no clicks land on it.
    xdotool windowminimize "$id"          2>/dev/null || true
    wmctrl -ir "$id" -b add,hidden        2>/dev/null || true
    xdotool windowunmap   "$id"           2>/dev/null || true
    xdotool windowmove    "$id" -3000 -3000 2>/dev/null || true
    count=$((count + 1))
  done
  log "minimize_steam_windows: hid $count window(s)"
}

# Dismiss whatever modal CEF dialog is currently overlaying the Steam UI
# (Cloud Out of Date "Play anyway", shader pre-cache "Skip", etc).
# Confirmed empirically: Space activates the default-focused button on
# Steam's CEF dialogs. No mouse, no button-position guessing — just
# trust the focus that's already there.
poke_steam_dialog() {
  local id
  id=$(find_main_steam_window)
  [ -z "$id" ] && return 0
  log "poke_steam_dialog: window=$id sending Space"
  wmctrl -ia "$id" 2>/dev/null || true
  xdotool windowactivate --sync "$id" 2>/dev/null || true
  sleep 0.1
  xdotool key --clearmodifiers space 2>/dev/null || true
}
