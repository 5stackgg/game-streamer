#!/usr/bin/env bash
# MODE=live — launches CS2 via Steam IPC to spectate a match, captures the
# X display + audio with GStreamer, publishes to MediaMTX over SRT.
#
# Assumes ../game-streamer.sh::prepare_runtime has already run (Steam
# logged in, CS2 installed/up-to-date, Xorg + audio up).
#
# Required env:
#   MATCH_ID                          path component for the published stream
#   one of:
#     CONNECT_ADDR + CONNECT_PASSWORD     regular +connect (Steam GC)
#     CONNECT_TV_ADDR + CONNECT_TV_PASSWORD   classic GOTV +connect_tv
#     PLAYCAST_URL [+ PLAYCAST_PASSWORD]      HTTP broadcast (no GC)
#
# Optional env:
#   MEDIAMTX_SRT_BASE   default srt://mediamtx.5stack.svc.cluster.local:8890
#   FPS, VIDEO_KBPS, AUDIO_KBPS, AUDIO=pulse
set -euo pipefail

LOG_TAG=live
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/cs2.sh
. "$SCRIPT_DIR/../lib/cs2.sh"
# shellcheck source=lib/gst.sh
. "$SCRIPT_DIR/../lib/gst.sh"

require_env MATCH_ID

if [ -z "${CONNECT_ADDR:-}" ] && [ -z "${CONNECT_TV_ADDR:-}" ] && [ -z "${PLAYCAST_URL:-}" ]; then
  log "ERROR: set CONNECT_ADDR | CONNECT_TV_ADDR | PLAYCAST_URL"
  exit 1
fi

# Build the autoexec that runs at CS2 startup. PLAYCAST_URL wins if both
# are set (HTTP broadcast is more common for our own match output).
declare -a autoexec_lines=( "con_enable 1" )
if [ -n "${PLAYCAST_URL:-}" ]; then
  if [ -n "${PLAYCAST_PASSWORD:-}" ]; then
    autoexec_lines+=( "playcast \"$PLAYCAST_URL\" \"$PLAYCAST_PASSWORD\"" )
  else
    autoexec_lines+=( "playcast \"$PLAYCAST_URL\"" )
  fi
elif [ -n "${CONNECT_ADDR:-}" ]; then
  # Single-line form matching the connect string the match server gives.
  autoexec_lines+=( "connect ${CONNECT_ADDR}; password ${CONNECT_PASSWORD:-}" )
else
  autoexec_lines+=( "connect_tv ${CONNECT_TV_ADDR} ${CONNECT_TV_PASSWORD:-}" )
fi

write_autoexec live_autoexec "${autoexec_lines[@]}"

# Append the static spectator-defaults file (volume, HUD, etc).
if [ -f "$REPO_DIR/resources/live_autoexec.cfg" ]; then
  cat "$REPO_DIR/resources/live_autoexec.cfg" >> "$CS2_DIR/game/csgo/cfg/live_autoexec.cfg"
fi

# Kill any prior cs2 + clear stale source-engine lock.
quit_cs2 hard

launch_cs2_via_steam \
  -fullscreen -width "$DISPLAY_SIZEW" -height "$DISPLAY_SIZEH" \
  -novid -nojoy -console \
  +exec live_autoexec

wait_for_cs2_window 240

capture_to_srt "$MATCH_ID"
