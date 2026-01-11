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
# Required env: STEAM_USER, STEAM_PASSWORD

set -uo pipefail
SCRIPT_TAG=setup-steam

# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/xorg.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/stream.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/audio.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/steam.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/openhud.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/spec-server.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/status-reporter.sh"

load_env
require_env STEAM_USER STEAM_PASSWORD

: "${DEBUG_STREAM_ID:=debug}"
: "${STEAM_PIPE_TIMEOUT:=300}"

start_status_reporter
report_status status=launching_steam

say "1. Xorg + openbox + X access"
start_xorg

say "1b. PulseAudio + cs2 null sink"
start_pulseaudio

# Spectator control daemon — exposes POST /spec/{click,jump,player,
# autodirector} on $SPEC_SERVER_PORT (default 1350). Lets the 5stack
# web app (or any HTTP client) drive cs2's spectator slot without a
# full remote-desktop session. Started before cs2 launches so the
# operator's first click after match start hits a ready endpoint.
say "1bb. spec-server (cs2 control HTTP daemon)"
start_spec_server

# OpenHud overlay stack. Brought up BEFORE Steam so the admin window has
# already been hidden by the time Steam's UI appears — avoids cosmetic
# Steam-on-top weirdness during the 90s shader-cache window. The overlay
# itself only matters once cs2 is up and run-live raises it.
say "1c. picom (compositor) + OpenHud server"
if [ -x "$OPENHUD_BIN" ]; then
  start_picom || warn "continuing without picom (HUD background won't be transparent)"
  start_openhud
  if wait_for_openhud_server 60; then
    hide_openhud_admin_window
    # Position+raise the overlay BEFORE Steam/cs2 ever launches. With
    # Electron's alwaysOnTop:true the HUD should stay on top once cs2
    # goes fullscreen — but if it gets pushed down anyway, run-live
    # re-raises it after cs2 spawns.
    position_openhud_overlay || warn "early overlay positioning failed — will retry after cs2"
  else
    warn "OpenHud server didn't come up — continuing without HUD overlay"
  fi
else
  log "OpenHud not installed at $OPENHUD_BIN — skipping HUD setup"
  log "  rebuild image with --build-arg OPENHUD_VERSION=vX.Y.Z to enable"
fi

if [ "${DEBUG_CAPTURE:-0}" = "1" ]; then
  say "2. debug capture stream"
  start_capture "$DEBUG_STREAM_ID" 30 4000 true 0
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
report_status status=downloading_cs2
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

say "6b. disable Steam in-game overlay (global + per-app)"
disable_overlay_globally
disable_cs2_overlay
print_overlay_state

say "7. launch Steam"
start_steam

say "8. wait for steam pipe"
wait_for_steam_pipe "$STEAM_PIPE_TIMEOUT" \
  || die "pipe never came up — check $LOG_DIR/steam.log and the debug stream"

# Wait for the UI window BEFORE attempting any first-boot cycle. The
# IPC pipe comes up well before login completes — at pipe-up time
# userdata/<steamid>/ may not exist yet. Cycling at that point would
# kill Steam mid-login, our disable_cs2_cloud would no-op (no
# userdata to edit), and Steam's second start would write fresh
# defaults — undoing the entire purpose of the cycle.
say "9. wait for main Steam window (login + UI render)"
report_status status=logging_in
wait_for_main_steam_window "${STEAM_WINDOW_TIMEOUT:-300}" \
  || die "main Steam window not visible — Steam may still be downloading runtimes"

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
  disable_overlay_globally
  disable_cs2_overlay
  print_overlay_state
  start_steam
  wait_for_steam_pipe "$STEAM_PIPE_TIMEOUT" \
    || die "pipe never came up after cycle — check $LOG_DIR/steam.log"
  wait_for_main_steam_window "${STEAM_WINDOW_TIMEOUT:-300}" \
    || die "main Steam window not visible after cycle"
fi

say "done"
log "Steam is fully up. next: src/game-streamer.sh run-live"
