#!/usr/bin/env bash
# Type a connect/playcast command into the CS2 console via xdotool.
# Run AFTER CS2 is up on main menu (run-live-debug.sh has fired).
#
# Required env (one of):
#   PLAYCAST_URL                       e.g. https://tv.5stack.gg/<id>
#   CONNECT_ADDR + CONNECT_PASSWORD    for +connect
#   CONNECT_TV_ADDR + CONNECT_TV_PASSWORD   for +connect_tv

set -uo pipefail

: "${DISPLAY:=:0}"

say() { printf '\n[console] %s\n' "$*"; }

# Decide which command to send.
CMDS=()
if [ -n "${PLAYCAST_URL:-}" ]; then
  CMDS+=( "playcast \"${PLAYCAST_URL}\"" )
elif [ -n "${CONNECT_ADDR:-}" ]; then
  : "${CONNECT_PASSWORD:?set CONNECT_PASSWORD when using CONNECT_ADDR}"
  # Single-line form (matches the connect string the match server gives).
  CMDS+=( "connect ${CONNECT_ADDR}; password ${CONNECT_PASSWORD}" )
elif [ -n "${CONNECT_TV_ADDR:-}" ]; then
  CMDS+=( "connect_tv ${CONNECT_TV_ADDR} ${CONNECT_TV_PASSWORD:-}" )
else
  say "ERROR: set PLAYCAST_URL OR CONNECT_ADDR+CONNECT_PASSWORD OR CONNECT_TV_ADDR"
  exit 1
fi

# Find the CS2 window (xdotool's --name search doesn't work for it).
WIN=$(xwininfo -display "$DISPLAY" -root -tree 2>/dev/null \
       | awk '/"Counter-Strike 2"/{print $1; exit}')
if [ -z "$WIN" ]; then
  say "no CS2 window found. Is it running?"
  exit 1
fi
say "CS2 window: $WIN"

# Bring window forward + focus + click center so SDL3 sees focus.
say "activating + focusing"
xdotool windowactivate --sync "$WIN" 2>/dev/null || true
xdotool windowfocus    --sync "$WIN" 2>/dev/null || true
xdotool windowraise    "$WIN"        2>/dev/null || true
xdotool mousemove --window "$WIN" 960 540
xdotool click 1
sleep 0.5

# Open console — input field is auto-focused, no click needed.
say "opening console (~ key)"
xdotool key --clearmodifiers grave
sleep 1

# Send each command line straight to the focused input.
for cmd in "${CMDS[@]}"; do
  say "typing: $cmd"
  xdotool type --clearmodifiers --delay 80 -- "$cmd"
  xdotool key --clearmodifiers Return
  sleep 1
done

say "done — watch the HLS stream"
say "  tail /tmp/cs2.log | grep -iE 'connect|playcast|broadcast|server'"
