#!/usr/bin/env bash
# Bring up real Steam (not gbe_fork stub) with UI visible on the HLS
# stream so we can interact with it via xdotool.
#
# Required env (already set in pod from secrets):
#   STEAM_USERNAME
#   STEAM_PASSWORD
#
# Usage:
#   ./scripts/run-steam-debug.sh start    # install + launch Steam
#   ./scripts/run-steam-debug.sh stop     # kill steam + restore stub
#   ./scripts/run-steam-debug.sh use-stub # switch back to gbe_fork
#   ./scripts/run-steam-debug.sh status

set -uo pipefail

: "${DISPLAY:=:0}"
: "${XDG_RUNTIME_DIR:=/tmp/xdg-runtime-root}"
: "${MEDIAMTX_SRT_BASE:=srt://mediamtx.5stack.svc.cluster.local:8890}"
: "${DEBUG_STREAM_ID:=debug}"

mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
export DISPLAY XDG_RUNTIME_DIR GTK_A11Y=none NO_AT_BRIDGE=1

SDK64_LINK=/root/.steam/sdk64/steamclient.so
SDK64_BACKUP=/root/.steam/sdk64/steamclient.so.real

say() { printf '\n=== %s ===\n' "$*"; }

ensure_xorg() {
  if pgrep -x Xorg >/dev/null 2>&1 && xdpyinfo >/dev/null 2>&1; then return 0; fi
  say "starting Xorg + openbox"
  rm -f /tmp/.X0-lock /tmp/.X11-unix/X0
  nohup Xorg "$DISPLAY" -config xorg-dummy.conf -noreset \
    -nolisten tcp -listen unix vt7 >/tmp/xorg.log 2>&1 &
  for _ in $(seq 1 20); do
    xdpyinfo >/dev/null 2>&1 && break
    sleep 0.5
  done
  xhost +local: >/dev/null 2>&1 || true
  xhost + >/dev/null 2>&1 || true
  pgrep -x openbox >/dev/null 2>&1 || \
    nohup openbox >/tmp/openbox.log 2>&1 &
  sleep 1
}

install_steam_bootstrap() {
  if [ -x /root/.local/share/Steam/steam.sh ]; then
    say "Steam bootstrap already extracted"
    return 0
  fi
  command -v xz >/dev/null 2>&1 || {
    say "installing xz-utils (needed to extract bootstrap)"
    apt-get update -qq && apt-get install -y -qq xz-utils
  }
  say "downloading + extracting Steam bootstrap"
  mkdir -p /root/.local/share/Steam
  curl -fsSL -o /tmp/steam.deb \
    https://cdn.cloudflare.steamstatic.com/client/installer/steam.deb
  dpkg-deb -x /tmp/steam.deb /tmp/steamdeb
  bootstrap=$(find /tmp/steamdeb -name 'bootstraplinux_ubuntu12_32.tar.xz' | head -1)
  tar -xJf "$bootstrap" -C /root/.local/share/Steam
  rm -rf /tmp/steam.deb /tmp/steamdeb
  ls /root/.local/share/Steam/steam.sh
}

restore_real_steamclient() {
  # If gbe_fork stub is active, swap back to real Steam runtime's steamclient.
  if [ -L "$SDK64_LINK" ] && readlink -f "$SDK64_LINK" | grep -q '/opt/gbe_fork'; then
    say "switching sdk64/steamclient.so back to real Steam runtime"
    if [ -e "$SDK64_BACKUP" ]; then
      rm -f "$SDK64_LINK"
      if [ -L "$SDK64_BACKUP" ]; then
        ln -sfn "$(readlink "$SDK64_BACKUP")" "$SDK64_LINK"
      else
        mv "$SDK64_BACKUP" "$SDK64_LINK"
      fi
    else
      # No backup — try to find one
      sc=$(find /root/.local/share/Steam -name 'steamclient.so' -path '*linux64*' 2>/dev/null | head -1)
      [ -n "$sc" ] && ln -sfn "$sc" "$SDK64_LINK"
    fi
    echo "  $SDK64_LINK -> $(readlink "$SDK64_LINK")"
  fi

  # Remove the steam_appid.txt that gbe_fork wanted (real Steam reads it
  # differently and it can confuse things).
  rm -f /mnt/game-streamer/cs2/game/csgo/steam_appid.txt
  rm -f /mnt/game-streamer/cs2/game/bin/linuxsteamrt64/steam_appid.txt
}

cmd_status() {
  say "STEAM CLIENT INSTALLED"
  ls /root/.local/share/Steam/steam.sh 2>/dev/null || echo "  not extracted"

  say "sdk64 STEAMCLIENT"
  ls -la "$SDK64_LINK" 2>/dev/null || echo "  missing"
  if [ -L "$SDK64_LINK" ]; then
    if readlink -f "$SDK64_LINK" | grep -q '/opt/gbe_fork'; then
      echo "  -> gbe_fork stub"
    else
      echo "  -> real Steam runtime"
    fi
  fi

  say "PROCESSES"
  pgrep -af 'steam|ubuntu12_32/steam|gst-launch' | grep -v 'state.sh\|run-steam-debug' || echo "  none"

  say "STEAM PIPE"
  if [ -p "$HOME/.steam/steam.pipe" ] && [ -f "$HOME/.steam/steam.pid" ]; then
    pid=$(cat "$HOME/.steam/steam.pid")
    if kill -0 "$pid" 2>/dev/null; then
      echo "  PIPE UP (pid $pid alive)"
    else
      echo "  pipe file exists but pid $pid DEAD (stale)"
    fi
  else
    echo "  no pipe"
  fi
}

cmd_start() {
  : "${STEAM_USERNAME:?set STEAM_USERNAME}"
  : "${STEAM_PASSWORD:?set STEAM_PASSWORD}"

  say "killing any stale steam / cs2"
  pkill -9 -f '/linuxsteamrt64/cs2' 2>/dev/null || true
  pkill -9 -f 'ubuntu12_32/steam'   2>/dev/null || true
  pkill -9 -f '/steam.sh'           2>/dev/null || true
  pkill -9 -x dbus-launch           2>/dev/null || true
  pkill -9 -f "publish:${DEBUG_STREAM_ID}" 2>/dev/null || true
  sleep 1
  rm -rf /tmp/dumps* /tmp/source_engine_*.lock /tmp/steam_pipe_*
  rm -f /mnt/game-streamer/steam/.crash 2>/dev/null || true
  rm -f "$HOME/.steam/steam.pid" "$HOME/.steam/steam.pipe" 2>/dev/null || true

  ensure_xorg
  install_steam_bootstrap
  restore_real_steamclient

  say "launching Steam (with UI, login prefilled)"
  echo "  output streams below prefixed with [steam]"
  (
    stdbuf -oL -eL dbus-launch --exit-with-session \
      /root/.local/share/Steam/steam.sh \
      -login "$STEAM_USERNAME" "$STEAM_PASSWORD" 2>&1 \
      | stdbuf -oL tee /tmp/steam_manual.log \
      | sed -u 's/^/  [steam] /' >&2
  ) &
  echo "  steam wrapper pid=$!"

  say "starting screen capture -> ${DEBUG_STREAM_ID}"
  nohup gst-launch-1.0 -e \
    ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer=true \
      ! video/x-raw,framerate=30/1 \
      ! videoconvert ! video/x-raw,format=NV12 \
      ! nvh264enc preset=low-latency-hq gop-size=60 bitrate=4000 rc-mode=cbr \
      ! h264parse config-interval=1 \
      ! mpegtsmux alignment=7 \
      ! srtsink uri="${MEDIAMTX_SRT_BASE}?streamid=publish:${DEBUG_STREAM_ID}" latency=200 \
      >/tmp/gst.log 2>&1 &
  echo "  gst-launch pid=$!"

  say "waiting for steam pipe (up to 180s)"
  for i in $(seq 1 180); do
    if [ -p "$HOME/.steam/steam.pipe" ] && [ -f "$HOME/.steam/steam.pid" ]; then
      pid=$(cat "$HOME/.steam/steam.pid")
      if kill -0 "$pid" 2>/dev/null; then
        echo "  PIPE UP after ${i}s (pid $pid)"
        break
      fi
    fi
    [ $(( i % 10 )) -eq 0 ] && echo "  still waiting (${i}s)"
    sleep 1
  done

  say "done"
  echo "  watch: https://hls.5stack.gg/${DEBUG_STREAM_ID}/"
  echo "  status: $0 status"
  echo "  if you see a login window, send keys via console-connect.sh's"
  echo "  helpers, or shell-in xdotool commands."
}

cmd_stop() {
  pkill -9 -f 'ubuntu12_32/steam' 2>/dev/null || true
  pkill -9 -f '/steam.sh'         2>/dev/null || true
  pkill -9 -x dbus-launch         2>/dev/null || true
  pkill -9 -f "publish:${DEBUG_STREAM_ID}" 2>/dev/null || true
  echo "stopped Steam + capture"
}

cmd_use_stub() {
  cmd_stop
  say "switching back to gbe_fork stub"
  /opt/5stack/scripts/install-gbe-fork.sh install
}

case "${1:-status}" in
  start)    cmd_start ;;
  stop)     cmd_stop ;;
  status)   cmd_status ;;
  use-stub) cmd_use_stub ;;
  *) echo "usage: $0 start | stop | status | use-stub"; exit 2 ;;
esac
