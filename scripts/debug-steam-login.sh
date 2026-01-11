#!/usr/bin/env bash
# Interactive Steam login helper — no secrets on command line.
#
# Required env (already set in the pod from secrets):
#   STEAM_USERNAME
#   STEAM_PASSWORD
#
# Optional:
#   MEDIAMTX_SRT_BASE   default srt://mediamtx.5stack.svc.cluster.local:8890
#   DEBUG_STREAM_ID     default "debug"
#   DISPLAY             default :0
#
# Usage:
#   ./scripts/debug-steam-login.sh start        # launches Steam + GStreamer capture
#   ./scripts/debug-steam-login.sh type-login   # types $STEAM_USERNAME + $STEAM_PASSWORD into the login window
#   ./scripts/debug-steam-login.sh type-code N  # types a 5-char Steam Guard code
#   ./scripts/debug-steam-login.sh windows      # list visible X windows
#   ./scripts/debug-steam-login.sh pipe         # check if /tmp/steam_pipe_* exists
#   ./scripts/debug-steam-login.sh stop         # kill steam + gst capture
#   ./scripts/debug-steam-login.sh help

set -euo pipefail

: "${DISPLAY:=:0}"
: "${MEDIAMTX_SRT_BASE:=srt://mediamtx.5stack.svc.cluster.local:8890}"
: "${DEBUG_STREAM_ID:=debug}"

log() { echo "[debug-login] $*"; }

ensure_xorg() {
  if pgrep -x Xorg >/dev/null 2>&1; then
    DISPLAY="$DISPLAY" xdpyinfo >/dev/null 2>&1 && return 0
  fi
  log "starting Xorg on $DISPLAY"
  rm -f /tmp/.X0-lock /tmp/.X11-unix/X0
  nohup Xorg "$DISPLAY" -config xorg-dummy.conf -noreset \
    -nolisten tcp -listen unix vt7 >/tmp/xorg.log 2>&1 &
  for _ in $(seq 1 20); do
    DISPLAY="$DISPLAY" xdpyinfo >/dev/null 2>&1 && break
    sleep 0.5
  done
  DISPLAY="$DISPLAY" xhost +local: >/dev/null 2>&1 || true
  pgrep -x openbox >/dev/null 2>&1 || \
    DISPLAY="$DISPLAY" nohup openbox >/tmp/openbox.log 2>&1 &
  sleep 1
}

cmd_start() {
  : "${STEAM_USERNAME:?STEAM_USERNAME not set}"
  : "${STEAM_PASSWORD:?STEAM_PASSWORD not set}"

  log "cleaning up prior steam / gst / dump state"
  # Be specific with pkill so we don't match our own script path
  # (which contains "steam").
  pkill -9 -f '/linuxsteamrt64/cs2' 2>/dev/null || true
  pkill -9 -x steam 2>/dev/null || true
  pkill -9 -f 'ubuntu12_32/steam' 2>/dev/null || true
  pkill -9 -f 'steamwebhelper' 2>/dev/null || true
  pkill -9 -f '/steam.sh' 2>/dev/null || true
  pkill -9 -x zenity 2>/dev/null || true
  pkill -9 -x dbus-launch 2>/dev/null || true
  pkill -9 -f "publish:${DEBUG_STREAM_ID}" 2>/dev/null || true
  sleep 1
  rm -rf /tmp/dumps* /tmp/source_engine_* /tmp/steam_pipe_* 2>/dev/null || true

  ensure_xorg

  log "launching Steam with UI (no -silent)"
  DISPLAY="$DISPLAY" GTK_A11Y=none NO_AT_BRIDGE=1 \
    dbus-launch --exit-with-session \
    /root/.local/share/Steam/steam.sh \
    >/tmp/steam_manual.log 2>&1 &
  log "steam launcher pid=$!"

  log "starting screen capture -> ${DEBUG_STREAM_ID}"
  nohup gst-launch-1.0 -e \
    ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer=true \
      ! video/x-raw,framerate=30/1 \
      ! videoconvert ! video/x-raw,format=NV12 \
      ! nvh264enc preset=low-latency-hq gop-size=60 bitrate=4000 rc-mode=cbr \
      ! h264parse config-interval=1 \
      ! mpegtsmux alignment=7 \
      ! srtsink uri="${MEDIAMTX_SRT_BASE}?streamid=publish:${DEBUG_STREAM_ID}" latency=200 \
      >/tmp/gst.log 2>&1 &
  log "gst-launch pid=$!"

  log ""
  log "  watch at: https://hls.5stack.gg/${DEBUG_STREAM_ID}/"
  log "  when the Steam login window appears, run:  $0 type-login"
  log ""
}

cmd_windows() {
  DISPLAY="$DISPLAY" xwininfo -root -tree 2>/dev/null \
    | grep -E '^\s+0x' | head -30
}

activate_steam_window() {
  local id
  id=$(DISPLAY="$DISPLAY" xdotool search --name "Steam" 2>/dev/null | head -1)
  [ -z "$id" ] && { log "no Steam window found"; return 1; }
  DISPLAY="$DISPLAY" xdotool windowactivate --sync "$id" 2>/dev/null || true
  echo "$id"
}

cmd_type_login() {
  : "${STEAM_USERNAME:?STEAM_USERNAME not set}"
  : "${STEAM_PASSWORD:?STEAM_PASSWORD not set}"
  local id
  id=$(activate_steam_window) || return 1
  log "typing credentials into window $id (no echo)"
  # username
  DISPLAY="$DISPLAY" xdotool type --delay 40 -- "$STEAM_USERNAME"
  DISPLAY="$DISPLAY" xdotool key Tab
  # password — piped in via stdin so it's never in argv/exports outside this script
  printf '%s' "$STEAM_PASSWORD" | DISPLAY="$DISPLAY" xdotool type --delay 40 --file -
  DISPLAY="$DISPLAY" xdotool key Return
  log "submitted — watch the HLS stream for the next prompt"
}

cmd_type_code() {
  local code="${1:-}"
  [ -z "$code" ] && { log "usage: $0 type-code <steam-guard-email-code>"; return 1; }
  activate_steam_window >/dev/null || true
  DISPLAY="$DISPLAY" xdotool type --delay 40 -- "$code"
  DISPLAY="$DISPLAY" xdotool key Return
  log "code submitted"
}

cmd_pipe() {
  # The pipe FIFO file persists on disk after Steam exits, so just checking
  # its existence is misleading. Also confirm the pid in steam.pid refers
  # to a live process.
  local pipe="$HOME/.steam/steam.pipe"
  local pid_file="$HOME/.steam/steam.pid"
  if [ -p "$pipe" ] && [ -f "$pid_file" ]; then
    local pid
    pid=$(cat "$pid_file")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      log "PIPE UP: $pipe (pid $pid alive)"
      return 0
    fi
    log "pipe file exists but Steam pid $pid is DEAD — stale state"
    return 1
  fi
  log "no pipe yet — steam not running"
  return 1
}

cmd_stop() {
  pkill -9 -x steam 2>/dev/null || true
  pkill -9 -f 'ubuntu12_32/steam' 2>/dev/null || true
  pkill -9 -f 'steamwebhelper' 2>/dev/null || true
  pkill -9 -f '/steam.sh' 2>/dev/null || true
  pkill -9 -x dbus-launch 2>/dev/null || true
  pkill -9 -f "publish:${DEBUG_STREAM_ID}" 2>/dev/null || true
  log "stopped"
}

cmd_help() {
  grep '^# ' "$0" | sed 's/^# //'
}

case "${1:-help}" in
  start)      cmd_start ;;
  type-login) cmd_type_login ;;
  type-code)  shift; cmd_type_code "${1:-}" ;;
  windows)    cmd_windows ;;
  pipe)       cmd_pipe ;;
  stop)       cmd_stop ;;
  help|*)     cmd_help ;;
esac
