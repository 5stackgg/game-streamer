#!/usr/bin/env bash
set -euo pipefail

log() { echo "[render] $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${CS2_DIR:=/mnt/game-streamer/steamapps/common/Counter-Strike Global Offensive}"
: "${DISPLAY:=:0}"
: "${DISPLAY_SIZEW:=1920}"
: "${DISPLAY_SIZEH:=1080}"
: "${FPS:=60}"
: "${VIDEO_KBPS:=8000}"
: "${CLIPS_DIR:=/mnt/game-streamer/clips}"
: "${DEMOS_DIR:=/mnt/game-streamer/demos}"
: "${XDG_RUNTIME_DIR:=/tmp/xdg-runtime-$(id -u)}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
export DISPLAY XDG_RUNTIME_DIR
: "${CLIP_LEAD_SECONDS:=5}"
: "${CLIP_TAIL_SECONDS:=3}"

: "${DEMO_PATH:?DEMO_PATH is required (path to .dem file)}"
: "${CLIP_NAME:?CLIP_NAME is required (output filename without extension)}"
: "${START_TICK:?START_TICK is required}"
: "${END_TICK:?END_TICK is required}"
: "${SPEC_SLOT:?SPEC_SLOT is required (CS2 spec_player slot number)}"

mkdir -p "$CLIPS_DIR"

CS2_LAUNCHER="$CS2_DIR/game/bin/linuxsteamrt64/cs2"
if [ ! -x "$CS2_LAUNCHER" ]; then
  log "ERROR: cs2 binary not found at $CS2_LAUNCHER"
  exit 1
fi
if [ ! -f "$DEMO_PATH" ]; then
  log "ERROR: demo file not found at $DEMO_PATH"
  exit 1
fi

if pgrep -f '/linuxsteamrt64/cs2' >/dev/null 2>&1; then
  log "killing stale cs2 process(es)"
  pkill -9 -f '/linuxsteamrt64/cs2' 2>/dev/null || true
  sleep 2
fi
rm -f /tmp/source_engine_*.lock 2>/dev/null || true

if ! pgrep -x steam >/dev/null 2>&1; then
  if [ -n "${STEAM_USERNAME:-}" ] && [ -n "${STEAM_PASSWORD:-}" ]; then
    STEAM_BIN=""
    for p in "$HOME/.local/share/Steam/steam.sh" /usr/games/steam /usr/bin/steam /usr/local/bin/steam "$(command -v steam 2>/dev/null)"; do
      [ -n "$p" ] && [ -x "$p" ] && { STEAM_BIN="$p"; break; }
    done
    if [ -n "$STEAM_BIN" ]; then
      log "starting $STEAM_BIN -silent -login $STEAM_USERNAME (via dbus-launch)"
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
    fi
  fi
fi

CS2_LIB_DIR="$CS2_DIR/game/bin/linuxsteamrt64"
for base in libpangoft2-1.0 libpango-1.0; do
  if [ ! -e "$CS2_LIB_DIR/${base}.so" ] && [ -e "$CS2_LIB_DIR/${base}.so.0" ]; then
    ln -sf "${base}.so.0" "$CS2_LIB_DIR/${base}.so" || true
  fi
done
if [ -L /usr/lib/x86_64-linux-gnu/libpangoft2-1.0.so ]; then
  rm -f /usr/lib/x86_64-linux-gnu/libpangoft2-1.0.so
fi
SYS_FREETYPE=/lib/x86_64-linux-gnu/libfreetype.so.6
CS2_LD_PRELOAD=""
[ -e "$SYS_FREETYPE" ] && CS2_LD_PRELOAD="$SYS_FREETYPE${LD_PRELOAD:+:$LD_PRELOAD}"
CS2_LD_LIBRARY_PATH="$CS2_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

CFG_DIR="$CS2_DIR/game/csgo/cfg"
mkdir -p "$CFG_DIR"

# CS2 demo tickrate is 64; lead-in/tail buffer expressed in ticks.
TICKRATE=64
LEAD_TICKS=$(( CLIP_LEAD_SECONDS * TICKRATE ))
TAIL_TICKS=$(( CLIP_TAIL_SECONDS * TICKRATE ))
GOTO_TICK=$(( START_TICK - LEAD_TICKS ))
[ "$GOTO_TICK" -lt 0 ] && GOTO_TICK=0
STOP_TICK=$(( END_TICK + TAIL_TICKS ))

CLIP_AUTOEXEC="$CFG_DIR/clip_autoexec.cfg"
cat > "$CLIP_AUTOEXEC" <<EOF
sv_cheats 1
host_framerate $FPS
cl_draw_only_deathnotices 1
cl_drawhud 1
demo_pause 1
demo_gototick $GOTO_TICK
spec_player $SPEC_SLOT
demo_resume
EOF

log "Launching CS2 playdemo: $DEMO_PATH  goto=$GOTO_TICK stop=$STOP_TICK slot=$SPEC_SLOT"
(
  cd "$(dirname "$CS2_LAUNCHER")"
  LD_PRELOAD="$CS2_LD_PRELOAD" \
  LD_LIBRARY_PATH="$CS2_LD_LIBRARY_PATH" \
  "$CS2_LAUNCHER" -fullscreen \
    -width "$DISPLAY_SIZEW" -height "$DISPLAY_SIZEH" \
    -novid -nojoy -nohltv \
    +playdemo "$DEMO_PATH" \
    +exec clip_autoexec \
    >/tmp/cs2-render.log 2>&1
) &
CS2_PID=$!

# Wait for CS2 window
for _ in $(seq 1 60); do
  xdotool search --name "Counter-Strike 2" >/dev/null 2>&1 && break
  sleep 1
done

# Duration: (stop - goto) / tickrate  (plus a small safety margin)
DURATION=$(( (STOP_TICK - GOTO_TICK) / TICKRATE + 2 ))
log "Recording for ${DURATION}s -> $CLIPS_DIR/${CLIP_NAME}.mp4"

GOP=$(( FPS * 2 ))
OUTPUT="$CLIPS_DIR/${CLIP_NAME}.mp4"

gst-launch-1.0 -e \
  ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer=false num-buffers=$(( DURATION * FPS )) \
    ! video/x-raw,framerate="$FPS"/1 \
    ! videoconvert ! video/x-raw,format=NV12 \
    ! nvh264enc preset=hq gop-size="$GOP" bitrate="$VIDEO_KBPS" rc-mode=cbr \
    ! h264parse \
    ! mp4mux faststart=true \
    ! filesink location="$OUTPUT"

log "Clip written: $OUTPUT"
kill -TERM "$CS2_PID" 2>/dev/null || true
wait "$CS2_PID" 2>/dev/null || true

if [ -n "${S3_BUCKET_CLIPS:-}" ] && [ -n "${S3_ENDPOINT:-}" ]; then
  log "Uploading to s3://${S3_BUCKET_CLIPS}/${CLIP_NAME}.mp4"
  "$SCRIPT_DIR/s3-upload.py" "$OUTPUT" "${S3_BUCKET_CLIPS}/${CLIP_NAME}.mp4"
fi
