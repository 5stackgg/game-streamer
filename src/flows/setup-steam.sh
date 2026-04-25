#!/usr/bin/env bash
# Flow 1 — bring up Steam in a state where CS2 can be launched/updated.
#
# What it does (idempotent, safe to re-run):
#   * Ensures Xorg + openbox are up
#   * Auto-starts the debug capture stream so you can watch login progress
#   * Migrates legacy CS2 install (if any) into the canonical library layout
#   * Registers $STEAM_LIBRARY as a Steam library folder
#   * Restores the real steamclient.so over any leftover gbe_fork stub
#   * Launches the Steam UI with login prefilled
#   * Waits for the Steam IPC pipe to come up
#
# After this, watch https://hls.5stack.gg/${DEBUG_STREAM_ID:-debug}/ until
# you see the friends list / main Steam window — then run flow 2 (run-live).
#
# Required env: STEAM_USERNAME, STEAM_PASSWORD

set -uo pipefail
SCRIPT_TAG=setup-steam

# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/xorg.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/stream.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/steam.sh"

load_env
require_env STEAM_USERNAME STEAM_PASSWORD

: "${DEBUG_STREAM_ID:=debug}"
: "${STEAM_PIPE_TIMEOUT:=300}"

say "1. Xorg + openbox + X access"
start_xorg

if [ "${DEBUG_CAPTURE:-0}" = "1" ]; then
  say "2. debug capture stream"
  start_capture "$DEBUG_STREAM_ID" 30 4000 true
  log "watch login: https://hls.5stack.gg/${DEBUG_STREAM_ID}/"
fi

say "3. clean up any prior Steam/cs2 processes"
kill_steam

say "4. register steam library at $STEAM_LIBRARY"
mkdir -p "$STEAM_LIBRARY/steamapps/common"
register_library "$STEAM_LIBRARY"

say "5. migrate legacy CS2 install (if present)"
migrate_legacy_cs2

# Must run while Steam is OFF — Steam clobbers localconfig.vdf on shutdown.
# Without this CS2 pops a "Cloud Out of Date" CEF dialog we can't auto-dismiss.
say "6. disable CS2 cloud sync"
disable_cs2_cloud

say "7. launch Steam"
start_steam

say "8. wait for steam pipe"
wait_for_steam_pipe "$STEAM_PIPE_TIMEOUT" || {
  warn "pipe never came up — check $LOG_DIR/steam.log and the debug stream"
  exit 1
}

say "done"
log "next: src/game-streamer.sh run-live  (after you see the main Steam window)"
