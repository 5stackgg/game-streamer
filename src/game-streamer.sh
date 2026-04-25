#!/usr/bin/env bash
# Container entry point + operator CLI.
#
# Without args (the container ENTRYPOINT path):
#   reads $MODE and runs the corresponding workload after prepare_runtime.
#   MODE=live          — exec actions/live.sh         (CS2 spectator → SRT)
#   MODE=create-clips  — exec actions/create-clips.sh (CS2 +playdemo → mp4) [DRAFT]
#   MODE=idle          — boot stack and sleep         (debug; for `kubectl exec`)
#
# With args (operator path — `kubectl exec ... game-streamer.sh <cmd>`):
#   state              — print pod state
#   debug-steam        — diagnose Steam IPC / library state
#   debug-cs2-crash    — launch CS2 standalone, capture core, gdb backtrace
#   console-connect    — type a connect command into CS2's console
#   quit-cs2 [hard]    — stop CS2 + GStreamer
#   update-cs2         — re-run authenticated steamcmd update (force)
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

# Single source of truth for what subcommands exist + how they map.
#   <cmd>:<dispatch-target>
# Dispatch target is either a dev script name (resolved against
# $SCRIPT_DIR/dev/) or a function name in this file.
SUBCOMMANDS=(
  "state:dev/state.sh"
  "debug-steam:dev/debug-steam-launch.sh"
  "debug-cs2-crash:dev/debug-cs2-crash.sh"
  "console-connect:dev/console-connect.sh"
  "quit-cs2:_cmd_quit_cs2"
  "update-cs2:_cmd_update_cs2"
  "help:_cmd_help"
)

_cmd_help() {
  awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/, ""); print}' "$0"
}
_cmd_quit_cs2()   { quit_cs2 "$@"; }
_cmd_update_cs2() {
  # Operator explicitly asked — bypass the install-cache fast-path.
  CS2_FORCE_UPDATE=1 install_or_update_cs2
}

_subcommand_names() {
  local entry
  for entry in "${SUBCOMMANDS[@]}"; do printf '%s\n' "${entry%%:*}"; done
}

_dispatch_subcommand() {
  local cmd="$1"; shift
  local entry name target
  for entry in "${SUBCOMMANDS[@]}"; do
    name="${entry%%:*}"
    target="${entry#*:}"
    [ "$name" = "$cmd" ] || continue
    if [ "${target#dev/}" != "$target" ]; then
      local script="$SCRIPT_DIR/$target"
      [ -x "$script" ] || { echo "missing: $script" >&2; exit 2; }
      exec "$script" "$@"
    else
      "$target" "$@"
    fi
    return 0
  done
  echo "unknown subcommand: $cmd" >&2
  echo "try: $(_subcommand_names | tr '\n' '|' | sed 's/|$//; s/|/ | /g')" >&2
  exit 2
}

if [ $# -gt 0 ]; then
  _dispatch_subcommand "$@"
  exit 0
fi

# ---- container entry path -------------------------------------------------

: "${MODE:=idle}"

cleanup() {
  log "shutting down"
  pkill -TERM -f cs2 2>/dev/null || true
  pkill -TERM -f gst-launch 2>/dev/null || true
  # Brief grace so children flush before we yank Xorg out from under them.
  sleep 2
  pkill -KILL -f cs2 2>/dev/null || true
  pkill -KILL -f gst-launch 2>/dev/null || true
  if [ -f /tmp/xorg.pid ]; then
    local xpid; xpid=$(cat /tmp/xorg.pid 2>/dev/null || true)
    [ -n "$xpid" ] && kill "$xpid" 2>/dev/null || true
  fi
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
    log "ERROR: MODE='$MODE' — expected 'live', 'create-clips', or 'idle'"
    exit 1
    ;;
esac
