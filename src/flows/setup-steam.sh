#!/usr/bin/env bash
# Flow 1 — bring up Steam in a state where CS2 can be launched/updated.
#
# What it does (idempotent, safe to re-run):
#   * Ensures Xorg + openbox are up
#   * Symlinks $STEAM_HOME into the cache mount so Steam state persists
#   * Fixes ownership/perms + nukes stale package cache
#   * Registers $STEAM_LIBRARY as a Steam library folder
#   * Installs/updates CS2 via steamcmd directly
#   * Disables Steam Cloud sync at every known location
#   * Launches the Steam UI with login prefilled
#   * Waits for the Steam IPC pipe + main UI window
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

# Symlink $STEAM_HOME into the persisted cache mount BEFORE we touch
# any Steam state. This avoids the dual-bind-mount EXDEV bug where
# /root/.local/share/Steam was its own bind mount of the same hostPath
# as /mnt/game-streamer — Steam's self-update rename across the two
# would fail with error 18.
say "3a. persist Steam home via symlink into cache mount"
ensure_steam_home_persist

# Fix lingering ownership/perms + nuke stale package cache. Must run
# AFTER kill_steam (so we're not racing Steam) and AFTER the persist
# symlink (so we operate on the right path).
say "3b. fix Steam-home permissions + nuke stale package cache"
fix_steam_perms

say "4. register steam library at $STEAM_LIBRARY"
mkdir -p "$STEAM_LIBRARY/steamapps/common"
register_library "$STEAM_LIBRARY"

# Install/update CS2 via steamcmd directly. Steam is OFF here (we
# killed it at step 3), so steamcmd and Steam won't fight over
# appmanifest. After this Steam picks up the install on launch and
# the Install dialog never appears.
say "5. install/update CS2 via steamcmd"
install_cs2_via_steamcmd

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

# Wait for the UI window BEFORE attempting any first-boot cycle. The
# IPC pipe comes up well before login completes — at pipe-up time
# userdata/<steamid>/ may not exist yet. Cycling at that point would
# kill Steam mid-login, our disable_cs2_cloud would no-op (no
# userdata to edit), and Steam's second start would write fresh
# defaults — undoing the entire purpose of the cycle.
say "9. wait for main Steam window (login + UI render)"
wait_for_main_steam_window "${STEAM_WINDOW_TIMEOUT:-300}" || {
  warn "main Steam window not visible — Steam may still be downloading runtimes"
  exit 1
}

# First-boot auto-cycle: Steam has now logged in and written a fresh
# localconfig.vdf + sharedconfig.vdf with cloud sync ENABLED.
# SIGKILL avoids a graceful shutdown (which would rewrite both files
# from in-memory state and undo our edits), then we edit + relaunch.
if [ "$HAD_USERDATA" = 0 ]; then
  say "10. first-boot: cycle Steam to apply cloud-sync disable"
  # Belt-and-suspenders: even though main window appeared, give the
  # roaming-config sync a moment to land sharedconfig.vdf on disk
  # before we SIGKILL.
  for _ in $(seq 1 20); do
    [ -d "$STEAM_HOME/userdata" ] && break
    sleep 0.5
  done
  kill_steam
  disable_cloud_globally
  disable_cloud_in_config_vdf
  disable_cs2_cloud
  print_cloud_state
  start_steam
  wait_for_steam_pipe "$STEAM_PIPE_TIMEOUT" || {
    warn "pipe never came up after cycle — check $LOG_DIR/steam.log"
    exit 1
  }
  wait_for_main_steam_window "${STEAM_WINDOW_TIMEOUT:-300}" || {
    warn "main Steam window not visible after cycle"
    exit 1
  }
fi

say "done"
log "Steam is fully up. next: src/game-streamer.sh run-live"
