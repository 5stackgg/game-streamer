#!/usr/bin/env bash
# Common helpers + env defaults sourced by every entrypoint script.

: "${CS2_DIR:=/mnt/game-streamer/steamapps/common/Counter-Strike Global Offensive}"
: "${PERSIST_DIR:=/mnt/game-streamer}"
: "${DISPLAY:=:0}"
: "${DISPLAY_SIZEW:=1920}"
: "${DISPLAY_SIZEH:=1080}"
: "${FPS:=60}"
: "${VIDEO_KBPS:=6000}"
: "${AUDIO_KBPS:=128}"
: "${AUDIO:=pulse}"
: "${MEDIAMTX_SRT_BASE:=srt://mediamtx.5stack.svc.cluster.local:8890}"
: "${XDG_RUNTIME_DIR:=/tmp/xdg-runtime-$(id -u)}"
: "${GTK_A11Y:=none}"
: "${NO_AT_BRIDGE:=1}"

mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null && chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null
export DISPLAY XDG_RUNTIME_DIR GTK_A11Y NO_AT_BRIDGE CS2_DIR PERSIST_DIR

log() { echo "[${LOG_TAG:-game-streamer}] $*"; }

require_env() {
  local var
  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      log "ERROR: $var is required"
      exit 1
    fi
  done
}
