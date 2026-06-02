# shellcheck shell=bash
# Xorg + openbox bringup. Idempotent.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

xorg_running() {
  pgrep -x Xorg >/dev/null 2>&1 && xdpyinfo -display "$DISPLAY" >/dev/null 2>&1
}

# Try to bind Xorg on :$n. Returns 0 if Xorg is up and answering, 1 if
# the display is owned (host desktop, foreign X, abstract-socket carcass)
# or Xorg otherwise failed. Never touches files belonging to a foreign X.
_try_start_xorg_on() {
  local n="$1"
  local disp=":$n"

  # Foreign X already answering → leave it alone, move on.
  if xdpyinfo -display "$disp" >/dev/null 2>&1; then
    log "xorg: $disp already has a live X server — skipping"
    return 1
  fi
  # Lock file owned by a process visible to us → foreign X in our ns,
  # don't clobber. (Cross-namespace owners won't be visible — the bind
  # attempt below is the real backstop for that case.)
  if [ -e "/tmp/.X${n}-lock" ]; then
    local owner
    owner=$(awk '{print $1+0; exit}' "/tmp/.X${n}-lock" 2>/dev/null)
    if [ -n "$owner" ] && [ "$owner" -gt 0 ] && kill -0 "$owner" 2>/dev/null; then
      log "xorg: $disp lock owned by live PID $owner — skipping"
      return 1
    fi
    rm -f "/tmp/.X${n}-lock" 2>/dev/null || true
  fi
  # Only safe to remove the socket file once we've ruled out a live owner.
  [ -S "/tmp/.X11-unix/X${n}" ] && rm -f "/tmp/.X11-unix/X${n}" 2>/dev/null || true

  log "starting Xorg on $disp"
  # Xorg.wrap (setuid) refuses absolute paths for -config — must be
  # a bare filename in Xorg's search path.
  local cmd=(Xorg "$disp" -config "$XORG_CONFIG" -noreset
             -nolisten tcp -listen unix vt7)
  spawn_logged xorg "${cmd[@]}"
  local xpid=$SPAWNED_PID
  local i
  for i in $(seq 1 20); do
    xdpyinfo -display "$disp" >/dev/null 2>&1 && return 0
    if ! kill -0 "$xpid" 2>/dev/null; then
      log "xorg: $disp bind failed (likely owned by foreign X in another ns)"
      return 1
    fi
    sleep 0.5
  done
  log "xorg: $disp never accepted clients within 10s — killing"
  kill "$xpid" 2>/dev/null || true
  return 1
}

start_xorg() {
  if xorg_running; then
    log "xorg already up on $DISPLAY"
  else
    # Host may already be running a desktop on :0 (gnome-shell etc.) and
    # bind-mount /tmp/.X11-unix into the pod — that collides with our
    # bind. Walk forward until we find a display we can actually claim,
    # then re-export DISPLAY so ximagesrc/xdotool/spectator follow.
    local start_n="${DISPLAY#:}" n found=""
    for n in $(seq "$start_n" $((start_n + 9))); do
      if _try_start_xorg_on "$n"; then
        found=":$n"
        break
      fi
    done
    [ -n "$found" ] || die "Xorg failed to start on any display in :$start_n..:$((start_n+9))"
    if [ "$found" != "$DISPLAY" ]; then
      log "xorg: requested $DISPLAY was taken — running on $found instead"
      export DISPLAY="$found"
    fi
  fi

  # Pin the resolved display so the next flow (run-demo / run-live, a
  # fresh process) inherits it instead of re-defaulting to :0. common.sh
  # reads this when DISPLAY isn't set in the env.
  printf '%s' "$DISPLAY" > "$LOG_DIR/display" 2>/dev/null || true

  if ! pgrep -x openbox >/dev/null 2>&1; then
    spawn_logged openbox openbox
    sleep 1
    pgrep -x openbox >/dev/null 2>&1 || warn "openbox didn't start"
  fi

  # Open X access so processes spawned outside our pgid can connect.
  xhost +local:           >/dev/null 2>&1 || true
  xhost +SI:localuser:root >/dev/null 2>&1 || true
}

stop_xorg() {
  pkill -x openbox 2>/dev/null || true
  pkill -x Xorg    2>/dev/null || true
}

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

# Find the main Steam UI window — largest "Steam"-named window at
# least 500x300. The real client is a child window deep in the X tree;
# xdotool's getwindowgeometry doesn't reliably handle that case.
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

# The pipe comes up before the UI does, and -applaunch issued before
# UI render sometimes hangs. Waits indefinitely; the api cancels by
# deleting the pod.
wait_for_main_steam_window() {
  log "waiting for the main Steam window"
  local i=0 id
  while :; do
    id=$(find_main_steam_window)
    if [ -n "$id" ]; then
      log "  ready after ${i}s: $id"
      return 0
    fi
    i=$(( i + 1 ))
    if [ $(( i % 15 )) -eq 0 ]; then
      log "  still waiting (${i}s)"
      list_x_windows
    fi
    sleep 1
  done
}

# Missed clicks on shader-skip / cloud-out-of-date dialogs were falling
# through and hitting Steam UI buttons (cancelling the launch, opening
# unrelated panels). Once cs2 is up, hide Steam.
minimize_steam_windows() {
  local main_id friends_id id
  main_id=$(find_main_steam_window)
  friends_id=$(xdotool search --name '^Friends List$' 2>/dev/null | head -1)
  for id in $main_id $friends_id; do
    [ -z "$id" ] && continue
    xdotool windowminimize "$id"            2>/dev/null || true
    wmctrl -ir "$id" -b add,hidden          2>/dev/null || true
    xdotool windowunmap   "$id"             2>/dev/null || true
    xdotool windowmove    "$id" -3000 -3000 2>/dev/null || true
  done
}

# Space activates the default-focused button on Steam's CEF modal
# dialogs (Cloud Out of Date, shader pre-cache, etc).
poke_steam_dialog() {
  local id
  id=$(find_main_steam_window)
  [ -z "$id" ] && return 0
  wmctrl -ia "$id" 2>/dev/null || true
  xdotool windowactivate --sync "$id" 2>/dev/null || true
  sleep 0.1
  xdotool key --clearmodifiers space 2>/dev/null || true
}

# Steam-blue "Play anyway" button colour; override if a build's accent differs.
: "${STEAM_BLUE:=#1a9fff}"

# Click "Play anyway" on the "Cloud Out of Date" CEF modal (it ignores keystrokes,
# so poke_steam_dialog won't work). Colour-finds the button in the Steam window's
# centre region; clicks only if found. Returns 0 if clicked, else 1.
dismiss_cloud_dialog() {
  command -v xdotool >/dev/null 2>&1 || return 1
  local wid
  wid=$(wmctrl -lx 2>/dev/null | awk '$3=="steamwebhelper.steam" && $NF=="Steam"{print $1; exit}')
  [ -z "$wid" ] && wid=$(find_main_steam_window 2>/dev/null)
  [ -z "$wid" ] && return 1

  local X Y WIDTH HEIGHT
  eval "$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null)" || return 1
  [ "${WIDTH:-0}" -gt 0 ] && [ "${HEIGHT:-0}" -gt 0 ] || return 1

  # Centre region where the modal lives.
  local cw ch cx cy
  cw=$(( WIDTH  * 60 / 100 )); ch=$(( HEIGHT * 55 / 100 ))
  cx=$(( WIDTH  * 20 / 100 )); cy=$(( HEIGHT * 25 / 100 ))

  # No ImageMagick → click by fixed offset from window centre (modal is centred).
  if ! command -v import >/dev/null 2>&1 || ! command -v convert >/dev/null 2>&1; then
    xdotool mousemove --sync $(( X + WIDTH/2 + ${CLOUD_BTN_DX:-90} )) $(( Y + HEIGHT/2 + ${CLOUD_BTN_DY:-104} )) click 1 2>/dev/null
    return 0
  fi

  local shot="${LOG_DIR:-/tmp}/cloud-modal.png"
  import -window "$wid" -crop "${cw}x${ch}+${cx}+${cy}" +repage "$shot" 2>/dev/null || return 1

  # Blue button → white, rest → black; read the blob bbox (WxH+X+Y in the crop).
  local geom bw bh bx by
  geom=$(convert "$shot" -fuzz 18% -fill white -opaque "$STEAM_BLUE" \
                 -fill black +opaque white -format '%@' info: 2>/dev/null)
  case "$geom" in *x*+*+*) : ;; *) return 1 ;; esac
  bw=${geom%%x*}; geom=${geom#*x}
  bh=${geom%%+*}; geom=${geom#*+}
  bx=${geom%%+*}; by=${geom##*+}

  # Reject a stray pixel or a region-filling match (= no distinct button).
  if ! { [ "${bw:-0}" -ge 24 ] && [ "${bw:-0}" -le $(( cw*70/100 )) ] \
         && [ "${bh:-0}" -ge 10 ] && [ "${bh:-0}" -le $(( ch*40/100 )); }; then
    log "dismiss_cloud_dialog: no Play-anyway button in modal region (blob ${bw:-?}x${bh:-?}) — not clicking"
    return 1
  fi

  local clickx clicky
  clickx=$(( X + cx + bx + bw/2 ))
  clicky=$(( Y + cy + by + bh/2 ))
  log "dismiss_cloud_dialog: clicking Play anyway at ${clickx},${clicky} (button ${bw}x${bh})"
  xdotool mousemove --sync "$clickx" "$clicky" click 1 2>/dev/null
  return 0
}
