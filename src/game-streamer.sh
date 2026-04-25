#!/usr/bin/env bash
# Container entry point + operator CLI.
#
# Without args (the container ENTRYPOINT path):
#   reads $MODE and runs the corresponding workload after the boot sequence.
#   MODE=live          — exec live.sh           (CS2 spectator → SRT publish)
#   MODE=create-clips  — exec create-clips.sh   (CS2 +playdemo → mp4) [DRAFT]
#
# With args (operator path — `kubectl exec ... game-streamer.sh <cmd>`):
#   state              — print pod state
#   debug-steam        — diagnose Steam IPC / library state
#   debug-cs2-crash    — launch CS2 standalone, capture core, gdb backtrace
#   console-connect    — type a connect command into CS2's console
#   quit-cs2 [hard]    — stop CS2 + GStreamer
#   update-cs2         — re-run authenticated steamcmd update
#   help               — this help

set -euo pipefail

LOG_TAG=game-streamer
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_DIR REPO_DIR

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/xorg.sh
. "$SCRIPT_DIR/lib/xorg.sh"
# shellcheck source=lib/audio.sh
. "$SCRIPT_DIR/lib/audio.sh"
# shellcheck source=lib/steam.sh
. "$SCRIPT_DIR/lib/steam.sh"
# shellcheck source=lib/cs2.sh
. "$SCRIPT_DIR/lib/cs2.sh"

# ---- operator subcommands -------------------------------------------------

if [ $# -gt 0 ]; then
  cmd="$1"; shift
  case "$cmd" in
    state|debug-steam-launch|debug-cs2-crash|console-connect)
      script="$SCRIPT_DIR/dev/${cmd}.sh"
      [ -x "$script" ] || { echo "missing: $script" >&2; exit 2; }
      exec "$script" "$@"
      ;;
    debug-steam)
      exec "$SCRIPT_DIR/dev/debug-steam-launch.sh" "$@"
      ;;
    quit-cs2)
      quit_cs2 "$@"
      ;;
    update-cs2)
      install_or_update_cs2
      ;;
    help|-h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      ;;
    *)
      echo "unknown subcommand: $cmd" >&2
      echo "try: state | debug-steam | debug-cs2-crash | console-connect | quit-cs2 | update-cs2 | help" >&2
      exit 2
      ;;
  esac
  exit 0
fi

# ---- container entry path -------------------------------------------------

# MODE=idle is an undocumented dev escape: container boots minimally and
# sleeps so an operator can `kubectl exec` and drive subcommands by hand.
: "${MODE:=idle}"

cleanup() {
  log "shutting down"
  [ -f /tmp/xorg.pid ] && kill "$(cat /tmp/xorg.pid)" 2>/dev/null || true
  pkill -TERM -f cs2 2>/dev/null || true
  pkill -TERM -f gst-launch 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log "MODE=$MODE"

# Common runtime that every action depends on. Each step is idempotent and
# safe to re-run; nothing here is action-specific. Actions in src/actions/
# are exec'd only after this completes.
prepare_runtime() {
  ensure_user_namespaces       # fail loud if the pod isn't privileged
  persist_steam_state          # symlink ~/.local/share/Steam to the hostPath
  ensure_steam_library         # register /mnt/game-streamer as a Steam library
  start_xorg                   # Xorg-dummy + openbox + xhost
  start_pulseaudio             # null sink "cs2" used as the GStreamer audio source
  start_steam                  # install Steam bootstrap if missing, then login
  ensure_steamclient           # symlink steamclient.so where CS2 expects it
  install_or_update_cs2        # authenticated steamcmd +app_update 730 validate
}

prepare_runtime

case "$MODE" in
  live)         exec "$SCRIPT_DIR/actions/live.sh" ;;
  create-clips) exec "$SCRIPT_DIR/actions/create-clips.sh" ;;
  idle)
    log "idle — sleeping. shell in: $SCRIPT_DIR/game-streamer.sh state"
    tail -f /dev/null
    ;;
  *)
    log "ERROR: MODE='$MODE' — expected 'live' or 'create-clips'"
    exit 1
    ;;
esac
