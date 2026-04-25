#!/usr/bin/env bash
# game-streamer — production entry point.
#
# Self-contained: only references files under src/. Two flows are kept
# deliberately separate so we can validate each step against the debug
# stream before chaining them.
#
#   1.  setup-steam            — flow 1: launch Steam (with login),
#                                register the steam library, disable
#                                CS2 cloud sync, wait for the IPC pipe.
#                                Pass --debug to also publish a screen
#                                capture so you can watch the login.
#   2.  run-live               — flow 2: -applaunch CS2 (Steam will
#                                update if needed) and start the match
#                                capture stream.
#
# Pass --debug as a top-level flag to publish an on-screen capture to
# publish:debug for the duration of the flow (watch at
# https://hls.5stack.gg/debug/). The debug-stream subcommand is also
# available for ad-hoc start/stop.
#
# Required env (load via src/.env, or export beforehand):
#   STEAM_USERNAME, STEAM_PASSWORD               (setup-steam)
#   MATCH_ID + (PLAYCAST_URL | CONNECT_ADDR & CONNECT_PASSWORD) (run-live)

set -uo pipefail
SCRIPT_TAG=game-streamer

# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/xorg.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/stream.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/steam.sh"

load_env

# Top-level flags (must come before the subcommand).
#   --debug : publish an on-screen capture stream to publish:$DEBUG_STREAM_ID
#             (default 'debug') for the duration of the run. Watch at
#             https://hls.5stack.gg/${DEBUG_STREAM_ID}/.
DEBUG_CAPTURE="${DEBUG_CAPTURE:-0}"
: "${DEBUG_STREAM_ID:=debug}"
while [ $# -gt 0 ]; do
  case "$1" in
    --debug)         DEBUG_CAPTURE=1; shift ;;
    --debug-id)      DEBUG_STREAM_ID="$2"; DEBUG_CAPTURE=1; shift 2 ;;
    --debug-id=*)    DEBUG_STREAM_ID="${1#*=}"; DEBUG_CAPTURE=1; shift ;;
    --trace|-x)      GS_TRACE=1; shift ;;
    --)              shift; break ;;
    *)               break ;;
  esac
done
export DEBUG_CAPTURE DEBUG_STREAM_ID GS_TRACE
[ "${GS_TRACE:-0}" = "1" ] && set -x

usage() {
  cat <<EOF
usage: $(basename "$0") [--debug] <command> [args]

flows:
  setup-steam              flow 1: register library + start Steam (UI visible)
  run-live                 flow 2: launch CS2 + start match capture
                           (requires flow 1 to have completed login)
  up                       run flow 1 then flow 2 end-to-end. Setup waits
                           until the main Steam UI window is rendered
                           before launching CS2.

global flags:
  --debug                  publish on-screen capture to publish:debug
                           (watch at https://hls.5stack.gg/debug/)
  --debug-id <id>          override the debug stream id (implies --debug)
  --trace, -x              set -x on every script (very loud, for debug)

debug stream (ad-hoc):
  debug-stream start [id]  start screen-capture stream (default id: 'debug')
  debug-stream stop  [id]
  debug-stream url   [id]  print HLS playback URL

control:
  status                   show xorg / steam / streams / cs2 / x windows
  windows                  print only the open X windows (cheap to poll)
  dismiss                  send Return to the Steam window
                           (clicks the focused button on any modal CEF dialog)
  dismiss-shader           click Skip on "Processing Vulkan shaders" dialog
  install-cs2              install/update CS2 via steamcmd into the
                           registered library (kills Steam, runs steamcmd,
                           leaves Steam off — re-run 'up' afterward).
                           Set CS2_FORCE_UPDATE=1 to force re-validate.
  steam-log                tail Steam's logs (steam.log, console-linux,
                           stderr, cef_log, webhelper-linux)
  debug [out-file]         full diagnostic dump (env, processes, pipe,
                           steamclient, binaries, runtime, user-namespaces,
                           windows, all logs, crash dumps, manifest, cloud
                           state, disk). Saves to $LOG_DIR/debug-*.txt.
  cloud-state              print Steam Cloud setting from disk (no edit)
  cloud-debug              verbose dump: file paths, mtimes, raw VDF
                           blocks (730 + Cloud + CloudEnabled), Steam
                           log lines mentioning cloud — use when the
                           dialog still appears despite disable-cloud
  disable-cloud            cycle Steam: kill -9 -> edit cloud=off -> relaunch
                           (use when 'Cloud Out of Date' dialog appears)
  stop-live                kill cs2 + match capture stream (keep Steam)
  stop-all                 kill cs2, capture, Steam, openbox, Xorg

env loaded from: $SRC_DIR/.env (if present)
log dir:         $LOG_DIR
EOF
}

cmd_status() {
  say "xorg"
  if xorg_running; then
    log "up on $DISPLAY"
  else
    log "not running"
  fi

  say "steam"
  if steam_pipe_up; then
    log "PIPE UP (pid $(cat "$HOME/.steam/steam.pid"))"
  else
    log "no pipe"
  fi
  if [ -L "$SDK64_LINK" ]; then
    log "sdk64/steamclient.so -> $(readlink -f "$SDK64_LINK")"
  fi

  say "cs2"
  local cs2_pid
  cs2_pid=$(pgrep -f '/linuxsteamrt64/cs2' | head -1)
  if [ -n "$cs2_pid" ]; then
    log "running (pid $cs2_pid)"
  else
    log "not running"
  fi

  say "capture streams"
  local found=0
  while IFS= read -r line; do
    log "  $line"
    found=1
  done < <(pgrep -af 'gst-launch.*publish:' || true)
  [ "$found" = 0 ] && log "  none"

  say "x windows"
  list_x_windows
}

cmd_debug_stream() {
  local sub="${1:-}"; shift || true
  local id="${1:-${DEBUG_STREAM_ID:-debug}}"
  case "$sub" in
    start)
      start_xorg
      start_capture "$id" 30 4000 true
      log "watch: https://hls.5stack.gg/${id}/"
      ;;
    stop)  stop_capture "$id" ;;
    url)   echo "https://hls.5stack.gg/${id}/" ;;
    *)     echo "usage: debug-stream start|stop|url [stream-id]" >&2; exit 2 ;;
  esac
}

cmd_stop_live() {
  pkill -9 -f '/linuxsteamrt64/cs2' 2>/dev/null || true
  if [ -n "${MATCH_ID:-}" ]; then
    stop_capture "$MATCH_ID"
  else
    log "MATCH_ID not set — skipping match capture stop"
  fi
}

cmd_stop_all() {
  cmd_stop_live
  stop_capture "${DEBUG_STREAM_ID:-debug}"
  kill_steam
  stop_xorg
  log "all stopped"
}

cmd_steam_log() {
  local f
  for f in "$LOG_DIR/steam.log" \
           "$STEAM_HOME/logs/console-linux.txt" \
           "$STEAM_HOME/logs/stderr.txt" \
           "$STEAM_HOME/logs/cef_log.txt" \
           "$STEAM_HOME/logs/webhelper-linux.txt"; do
    dump_log "$f" 60
  done
}

# Comprehensive single-command dump. Always also writes the same output
# to a file so it can be diffed/grepped after the fact without
# re-collecting.
cmd_debug() {
  local out="${1:-$LOG_DIR/debug-$(date +%Y%m%d-%H%M%S).txt}"
  log "writing full debug dump to $out (and stdout)"
  print_full_debug 2>&1 | tee "$out"
  log "saved to $out"
}

cmd_install_cs2() {
  require_env STEAM_USERNAME STEAM_PASSWORD
  say "kill Steam (steamcmd + Steam clash on appmanifest writes)"
  kill_steam
  say "register library + install CS2 via steamcmd"
  register_library "$STEAM_LIBRARY"
  install_cs2_via_steamcmd
  log "done. Re-run 'src/game-streamer.sh up' to bring Steam back up + launch"
}

cmd_disable_cloud() {
  require_env STEAM_USERNAME STEAM_PASSWORD
  say "kill Steam (-9 — no graceful shutdown so the file edit isn't clobbered)"
  kill_steam
  say "edit registry.vdf + config.vdf + localconfig.vdf + sharedconfig.vdf"
  disable_cloud_globally
  disable_cloud_in_config_vdf
  disable_cs2_cloud
  print_cloud_state
  say "relaunch Steam"
  start_steam
  wait_for_steam_pipe "${STEAM_PIPE_TIMEOUT:-300}"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  setup-steam)  exec "$FLOWS_DIR/setup-steam.sh" "$@" ;;
  run-live)     exec "$FLOWS_DIR/run-live.sh"    "$@" ;;
  up)
    "$FLOWS_DIR/setup-steam.sh" "$@" || exit $?
    exec "$FLOWS_DIR/run-live.sh" "$@"
    ;;
  debug-stream) cmd_debug_stream "$@" ;;
  status|state)   cmd_status ;;
  windows)        list_x_windows ;;
  dismiss)         poke_steam_dialog_verbose ;;
  dismiss-shader)  dismiss_shader_dialog ;;
  install-cs2)    cmd_install_cs2 ;;
  steam-log)      cmd_steam_log ;;
  debug)          cmd_debug "$@" ;;
  cloud-state)    print_cloud_state ;;
  cloud-debug)    print_cloud_debug ;;
  disable-cloud)  cmd_disable_cloud ;;
  stop-live)      cmd_stop_live ;;
  stop-all)       cmd_stop_all ;;
  -h|--help|help|"") usage ;;
  *) echo "unknown command: $cmd" >&2; usage >&2; exit 2 ;;
esac
