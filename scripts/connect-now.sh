#!/usr/bin/env bash
# Drop the CS2 console and send connect commands via xdotool.
# Run this AFTER run-live-debug.sh has CS2 up on the main menu.
#
# Required env:
#   CONNECT_ADDR      e.g. 76.139.106.28:30037
#   CONNECT_PASSWORD  e.g. tv:user:xxx
# Optional:
#   CONNECT_MODE=tv   use +connect_tv instead of +connect

set -uo pipefail

: "${CONNECT_ADDR:?set CONNECT_ADDR}"
: "${CONNECT_PASSWORD:?set CONNECT_PASSWORD}"
: "${DISPLAY:=:0}"
: "${CONNECT_MODE:=connect}"

say() { printf '\n[connect] %s\n' "$*"; }

say "finding CS2 window"
WIN=$(DISPLAY="$DISPLAY" xdotool search --name "Counter-Strike 2" 2>/dev/null | head -1)
if [ -z "$WIN" ]; then
  say "no CS2 window found. Is it running?"
  exit 1
fi
say "CS2 window: $WIN"

DISPLAY="$DISPLAY" xdotool windowactivate --sync "$WIN" || true
sleep 1

# Open the developer console. CS2's default bind is the backtick/tilde
# (`~`) which xdotool names "grave".
say "opening console"
DISPLAY="$DISPLAY" xdotool key --window "$WIN" grave
sleep 1

# Clear any partial input
DISPLAY="$DISPLAY" xdotool key --window "$WIN" ctrl+a
DISPLAY="$DISPLAY" xdotool key --window "$WIN" Delete

case "$CONNECT_MODE" in
  tv)
    say "typing: connect_tv $CONNECT_ADDR <password>"
    DISPLAY="$DISPLAY" xdotool type --window "$WIN" --delay 40 -- "connect_tv $CONNECT_ADDR $CONNECT_PASSWORD"
    ;;
  *)
    # For regular +connect, set the password first (it's stored separately)
    # then issue the connect. Both commands go into the same console.
    say "typing password cvar"
    DISPLAY="$DISPLAY" xdotool type --window "$WIN" --delay 40 -- "password \"$CONNECT_PASSWORD\""
    DISPLAY="$DISPLAY" xdotool key --window "$WIN" Return
    sleep 0.5
    say "typing: connect $CONNECT_ADDR"
    DISPLAY="$DISPLAY" xdotool type --window "$WIN" --delay 40 -- "connect $CONNECT_ADDR"
    ;;
esac
DISPLAY="$DISPLAY" xdotool key --window "$WIN" Return
sleep 1

# Close the console so we can see the game
say "closing console"
DISPLAY="$DISPLAY" xdotool key --window "$WIN" grave

say "done. watch the HLS stream for 'Connecting…'."
say "if nothing changes, tail /tmp/cs2.log for auth/network errors."
