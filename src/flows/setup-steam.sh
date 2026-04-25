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
# On first boot there's no userdata/ yet, so this is a no-op; we cycle Steam
# below once Steam has written its initial localconfig.vdf.
HAD_USERDATA=0
[ -d "$STEAM_HOME/userdata" ] && HAD_USERDATA=1

say "6. disable Steam Cloud sync (global + per-app)"
disable_cloud_globally
disable_cloud_in_config_vdf
disable_cs2_cloud
print_cloud_state

say "7. launch Steam"
start_steam

say "8. wait for steam pipe"
wait_for_steam_pipe "$STEAM_PIPE_TIMEOUT" || {
  warn "pipe never came up — check $LOG_DIR/steam.log and the debug stream"
  exit 1
}

# First-boot auto-cycle: Steam just wrote a fresh localconfig.vdf with
# cloudenabled=1. SIGKILL avoids a graceful shutdown (which would rewrite
# the file from in-memory state and undo our edit), then we edit + relaunch.
if [ "$HAD_USERDATA" = 0 ]; then
  say "9. first-boot: cycle Steam to apply cloud-sync disable"
  kill_steam
  disable_cloud_globally
  disable_cs2_cloud
  print_cloud_state
  start_steam
  wait_for_steam_pipe "$STEAM_PIPE_TIMEOUT" || {
    warn "pipe never came up after cycle — check $LOG_DIR/steam.log"
    exit 1
  }
fi

# The IPC pipe comes up before the UI is rendered. Issuing -applaunch
# before the main window exists can hang Steam; wait for the actual
# 1280x800 Steam client window before declaring "ready".
say "10. wait for main Steam window (login + UI render)"
wait_for_main_steam_window "${STEAM_WINDOW_TIMEOUT:-300}" || {
  warn "main Steam window not visible — Steam may still be downloading runtimes"
  exit 1
}

say "done"
log "Steam is fully up. next: src/game-streamer.sh run-live"
