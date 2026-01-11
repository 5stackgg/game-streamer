#!/usr/bin/env bash
set -euo pipefail

log() { echo "[live] $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${CS2_DIR:=/mnt/game-streamer/steamapps/common/Counter-Strike Global Offensive}"
: "${DISPLAY:=:0}"
: "${DISPLAY_SIZEW:=1920}"
: "${DISPLAY_SIZEH:=1080}"
: "${FPS:=60}"
: "${VIDEO_KBPS:=6000}"
: "${AUDIO_KBPS:=128}"
: "${MATCH_ID:?MATCH_ID is required}"
: "${XDG_RUNTIME_DIR:=/tmp/xdg-runtime-$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
export DISPLAY XDG_RUNTIME_DIR

# One of these must be set:
#   CONNECT_ADDR      host:port — regular +connect (with optional CONNECT_PASSWORD)
#   CONNECT_TV_ADDR   host:port of a GOTV server (classic +connect_tv, TCP)
#   PLAYCAST_URL      full https://... URL of an HTTP broadcast (e.g. tv.5stack.gg/<id>)
if [ -z "${CONNECT_ADDR:-}" ] && [ -z "${CONNECT_TV_ADDR:-}" ] && [ -z "${PLAYCAST_URL:-}" ]; then
  log "ERROR: set CONNECT_ADDR=<host:port> | CONNECT_TV_ADDR=<host:port> | PLAYCAST_URL=https://..."
  exit 1
fi

CONNECT_PASSWORD="${CONNECT_PASSWORD:-}"
CONNECT_TV_PASSWORD="${CONNECT_TV_PASSWORD:-}"

# Pick ingest transport. SRT is default — more reliable than WHIP under load,
# speaks H.264 directly, and MediaMTX accepts a `publish:<path>` streamid.
INGEST_MODE=""
MEDIAMTX_SRT_URL=""
if [ -n "${MEDIAMTX_SRT_BASE:-}" ]; then
  INGEST_MODE="srt"
  MEDIAMTX_SRT_URL="${MEDIAMTX_SRT_BASE}?streamid=publish:${MATCH_ID}"
elif [ -n "${MEDIAMTX_WHIP_URL:-}" ]; then
  INGEST_MODE="whip"
else
  log "ERROR: set MEDIAMTX_SRT_BASE or MEDIAMTX_WHIP_URL"
  exit 1
fi

# Call the cs2 binary directly. Valve's cs2.sh wrapper *requires* the Steam
# Linux Runtime (sniper) and aborts with "It appears cs2.sh was not launched
# within the Steam for Linux sniper runtime environment" outside of it.
CS2_LAUNCHER="$CS2_DIR/game/bin/linuxsteamrt64/cs2"
if [ ! -x "$CS2_LAUNCHER" ]; then
  log "ERROR: cs2 binary not found at $CS2_LAUNCHER"
  exit 1
fi
log "using binary: $CS2_LAUNCHER"

# Kill any prior cs2 process and clean up the engine lock; a second
# instance can't initialize while /tmp/source_engine_*.lock is held.
if pgrep -f '/linuxsteamrt64/cs2' >/dev/null 2>&1; then
  log "killing stale cs2 process(es)"
  pkill -9 -f '/linuxsteamrt64/cs2' 2>/dev/null || true
  sleep 2
fi
rm -f /tmp/source_engine_*.lock 2>/dev/null || true

# Skip starting real Steam when the gbe_fork stub is installed — the stub
# answers CS2's IPC calls on its own, no Steam process needed.
STEAMCLIENT_LINK="$HOME/.steam/sdk64/steamclient.so"
if [ -L "$STEAMCLIENT_LINK" ] && readlink -f "$STEAMCLIENT_LINK" | grep -q '/opt/gbe_fork'; then
  log "gbe_fork stub active — skipping Steam client startup"
elif ! pgrep -x steam >/dev/null 2>&1; then
  if [ -n "${STEAM_USERNAME:-}" ] && [ -n "${STEAM_PASSWORD:-}" ]; then
    STEAM_BIN=""
    for p in "$HOME/.local/share/Steam/steam.sh" /usr/games/steam /usr/bin/steam /usr/local/bin/steam "$(command -v steam 2>/dev/null)"; do
      [ -n "$p" ] && [ -x "$p" ] && { STEAM_BIN="$p"; break; }
    done
    if [ -n "$STEAM_BIN" ]; then
      log "starting $STEAM_BIN -silent -login $STEAM_USERNAME (via dbus-launch)"
      log "  — steam output streams below, prefixed with [steam]"
      (
        stdbuf -oL -eL dbus-launch --exit-with-session \
          "$STEAM_BIN" -silent -login "$STEAM_USERNAME" "$STEAM_PASSWORD" 2>&1 \
          | stdbuf -oL tee /tmp/steam.log \
          | sed -u 's/^/  [steam] /' >&2
      ) &
      for i in $(seq 1 180); do
        ls /tmp/steam_pipe_* >/dev/null 2>&1 && { log "steam IPC pipe up after ${i}s"; break; }
        [ $(( i % 10 )) -eq 0 ] && log "  (waiting for steam IPC pipe — ${i}s)"
        sleep 1
      done
    else
      log "WARN: steam binary not found — rebuild image with steam-installer"
    fi
  else
    log "WARN: no STEAM_USERNAME/STEAM_PASSWORD set — CS2 will fail IPC to Steam"
  fi
fi

# CS2's bundled libpangoft2 has a custom symbol (fontconfig_ft2_new_face_substitute)
# that system libpangoft2 doesn't export — so we need CS2's bundle to win
# when libpanorama_text_pango dlopens "libpangoft2-1.0.so" by bare name.
# Create the unversioned symlinks inside CS2's lib dir so LD_LIBRARY_PATH
# picks them up.
CS2_LIB_DIR="$CS2_DIR/game/bin/linuxsteamrt64"
for base in libpangoft2-1.0 libpango-1.0; do
  if [ ! -e "$CS2_LIB_DIR/${base}.so" ] && [ -e "$CS2_LIB_DIR/${base}.so.0" ]; then
    ln -sf "${base}.so.0" "$CS2_LIB_DIR/${base}.so" || log "WARN: couldn't link $base"
  fi
done
# Remove any stale system-side symlink from earlier (wrong target).
if [ -L /usr/lib/x86_64-linux-gnu/libpangoft2-1.0.so ]; then
  rm -f /usr/lib/x86_64-linux-gnu/libpangoft2-1.0.so
fi

# CS2's bundled libfreetype.so.6 (found first via rpath $ORIGIN) is missing
# FT_Get_Color_Glyph_Layer which system libharfbuzz needs. LD_PRELOAD system
# freetype so it wins regardless of search order.
SYS_FREETYPE=/lib/x86_64-linux-gnu/libfreetype.so.6
if [ -e "$SYS_FREETYPE" ]; then
  CS2_LD_PRELOAD="$SYS_FREETYPE${LD_PRELOAD:+:$LD_PRELOAD}"
else
  CS2_LD_PRELOAD="${LD_PRELOAD:-}"
fi

CS2_LD_LIBRARY_PATH="$CS2_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

LIVE_CFG_DIR="$CS2_DIR/game/csgo/cfg"
mkdir -p "$LIVE_CFG_DIR"
if [ -f "$REPO_DIR/cfg/live_autoexec.cfg" ]; then
  cp -f "$REPO_DIR/cfg/live_autoexec.cfg" "$LIVE_CFG_DIR/live_autoexec.cfg"
else
  log "WARN: no live_autoexec.cfg alongside $REPO_DIR — continuing without one"
fi

# Build launch arg list based on which input was provided. playcast wins
# if both are set (HTTP broadcast is more common for our own broadcasts).
CS2_ARGS=(
  -fullscreen
  -width "$DISPLAY_SIZEW" -height "$DISPLAY_SIZEH"
  -novid -nojoy
)
if [ -n "${PLAYCAST_URL:-}" ]; then
  log "Launching CS2 playcast -> $PLAYCAST_URL"
  if [ -n "${PLAYCAST_PASSWORD:-}" ]; then
    CS2_ARGS+=( +playcast "$PLAYCAST_URL" "$PLAYCAST_PASSWORD" )
  else
    CS2_ARGS+=( +playcast "$PLAYCAST_URL" )
  fi
elif [ -n "${CONNECT_ADDR:-}" ]; then
  log "Launching CS2 +connect -> $CONNECT_ADDR"
  # +password must come before +connect so the server sees it on auth.
  if [ -n "$CONNECT_PASSWORD" ]; then
    CS2_ARGS+=( +password "$CONNECT_PASSWORD" )
  fi
  CS2_ARGS+=( +connect "$CONNECT_ADDR" )
else
  log "Launching CS2 GOTV spectator -> $CONNECT_TV_ADDR"
  CS2_ARGS+=( -nohltv +connect_tv "$CONNECT_TV_ADDR" "$CONNECT_TV_PASSWORD" )
fi
CS2_ARGS+=( +exec live_autoexec )

(
  cd "$(dirname "$CS2_LAUNCHER")"
  LD_PRELOAD="$CS2_LD_PRELOAD" \
  LD_LIBRARY_PATH="$CS2_LD_LIBRARY_PATH" \
  "$CS2_LAUNCHER" "${CS2_ARGS[@]}" \
    >/tmp/cs2.log 2>&1
) &
CS2_PID=$!
log "CS2 pid=$CS2_PID"

# Wait for CS2 window. CS2 may take >60s past SteamAPI init when it's
# retrying a Steam network handshake; cap the wait at 4 minutes. Match on
# name substring, class, or any window owned by the cs2 pid.
cs2_window_exists() {
  # xwininfo is more reliable than xdotool search in headless Xorg — it
  # reads the X tree directly rather than relying on window manager
  # properties that Panorama doesn't always set.
  xwininfo -display "$DISPLAY" -root -tree 2>/dev/null | grep -q 'Counter-Strike'
}

CS2_WINDOW_UP=0
for i in $(seq 1 240); do
  if cs2_window_exists; then
    log "CS2 window detected after ${i}s"
    CS2_WINDOW_UP=1
    break
  fi
  if ! kill -0 "$CS2_PID" 2>/dev/null; then
    log "ERROR: CS2 process exited before window appeared. Last 60 lines of /tmp/cs2.log:"
    tail -n 60 /tmp/cs2.log >&2 || true
    exit 1
  fi
  if [ $(( i % 10 )) -eq 0 ]; then
    log "waiting for CS2 window... (${i}s, pid=$CS2_PID still up)"
  fi
  sleep 1
done
if [ "$CS2_WINDOW_UP" != "1" ]; then
  log "ERROR: CS2 window never appeared. Last 80 lines of /tmp/cs2.log:"
  tail -n 80 /tmp/cs2.log >&2 || true
  log "--- all windows on $DISPLAY ---"
  xwininfo -root -tree 2>&1 | head -40 >&2 || true
  exit 1
fi

GOP=$(( FPS * 2 ))

# Audio: default off. The container has no PulseAudio daemon by default,
# and CS2 running in spectate/playcast mode doesn't need mic input. Set
# AUDIO=pulse only if you've started a pulse daemon inside the pod.
AUDIO="${AUDIO:-none}"

case "$INGEST_MODE" in
  srt)
    log "Publishing to SRT (audio=$AUDIO): $MEDIAMTX_SRT_URL"
    if [ "$AUDIO" = "pulse" ]; then
      exec gst-launch-1.0 -e \
        ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer=false \
          ! video/x-raw,framerate="$FPS"/1 \
          ! videoconvert ! video/x-raw,format=NV12 \
          ! nvh264enc preset=low-latency-hq gop-size="$GOP" bitrate="$VIDEO_KBPS" rc-mode=cbr \
          ! h264parse config-interval=1 \
          ! mpegtsmux alignment=7 name=mux \
          ! srtsink uri="$MEDIAMTX_SRT_URL" latency=200 \
        pulsesrc \
          ! audioconvert ! audioresample \
          ! avenc_aac bitrate=$(( AUDIO_KBPS * 1000 )) \
          ! aacparse ! mux.
    else
      exec gst-launch-1.0 -e \
        ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer=false \
          ! video/x-raw,framerate="$FPS"/1 \
          ! videoconvert ! video/x-raw,format=NV12 \
          ! nvh264enc preset=low-latency-hq gop-size="$GOP" bitrate="$VIDEO_KBPS" rc-mode=cbr \
          ! h264parse config-interval=1 \
          ! mpegtsmux alignment=7 \
          ! srtsink uri="$MEDIAMTX_SRT_URL" latency=200
    fi
    ;;
  whip)
    log "Publishing to WHIP (audio=$AUDIO): $MEDIAMTX_WHIP_URL"
    exec gst-launch-1.0 -e \
      ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer=false \
        ! video/x-raw,framerate="$FPS"/1 \
        ! videoconvert ! video/x-raw,format=NV12 \
        ! nvh264enc preset=low-latency-hq gop-size="$GOP" bitrate="$VIDEO_KBPS" rc-mode=cbr \
        ! h264parse config-interval=1 \
        ! rtph264pay pt=96 \
        ! whipclientsink signaller::whip-endpoint="$MEDIAMTX_WHIP_URL"
    ;;
esac
