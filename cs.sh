if [ "$LAUNCH_STEAM" = "1" ] && command -v sudo >/dev/null 2>&1; then
  echo "Refreshing apt package cache..."
  sudo -n apt-get update >/dev/null 2>&1 || true
fi

if [ "$LAUNCH_STEAM" = "1" ]; then
  # Optional pre-run to ensure client updates are fetched even if UI is closed quickly
  if [ "$STEAM_AUTO_UPDATE" = "1" ]; then
    echo "Priming Steam auto-update (silent)..."
    if command -v steam >/dev/null 2>&1; then
      steam -silent >/dev/null 2>&1 &
    elif [ -x /usr/games/steam ]; then
      /usr/games/steam -silent >/dev/null 2>&1 &
    fi
    sleep 25 || true
    pkill -f "[s]team" >/dev/null 2>&1 || true
  fi

  echo "Launching Steam GUI..."
  if command -v steam >/dev/null 2>&1; then
    steam ${STEAM_ARGS} >/dev/null 2>&1 &
  elif [ -x /usr/games/steam ]; then
    /usr/games/steam ${STEAM_ARGS} >/dev/null 2>&1 &
  else
    echo "Steam not found in PATH."
  fi
fi

if [ "$LAUNCH_CS2" = "1" ]; then
  # Locate CS2 install (no steamcmd usage). Expect cs2.sh to exist already.
  echo "Locating CS2 launch script (cs2.sh)..."
  CS2_LAUNCH_SCRIPT=""

  # 1) If CS2_DIR is provided and valid, use it
  if [ -n "$CS2_DIR" ] && [ -f "$CS2_DIR/cs2.sh" ]; then
    CS2_LAUNCH_SCRIPT="$CS2_DIR/cs2.sh"
  fi

  # 2) Otherwise, try common Steam library paths
  if [ -z "$CS2_LAUNCH_SCRIPT" ]; then
    CANDIDATE_BASES=("$HOME/.local/share/Steam/steamapps/common" "$HOME/.steam/steam/steamapps/common")
    for base in "${CANDIDATE_BASES[@]}"; do
      # Known folder name
      if [ -f "$base/Counter-Strike Global Offensive/cs2.sh" ]; then
        CS2_LAUNCH_SCRIPT="$base/Counter-Strike Global Offensive/cs2.sh"
        break
      fi
      # Fallback search
      if [ -d "$base" ]; then
        found=$(find "$base" -maxdepth 2 -type f -name cs2.sh 2>/dev/null | head -n1 || true)
        if [ -n "${found}" ]; then
          CS2_LAUNCH_SCRIPT="$found"
          break
        fi
      fi
    done
  fi

  if [ -z "${CS2_LAUNCH_SCRIPT}" ]; then
    echo "cs2.sh not found. Skipping CS2 launch."
  else
    echo "Launching CS2..."
    if [ -n "$CONNECT_ADDR" ]; then
      "$CS2_LAUNCH_SCRIPT" -fullscreen +connect_tv "$CONNECT_ADDR" &
    elif [ -f "$DEMO_PATH" ]; then
      "$CS2_LAUNCH_SCRIPT" -fullscreen +playdemo "$DEMO_PATH" &
    else
      "$CS2_LAUNCH_SCRIPT" -fullscreen &
    fi
  fi
fi

sleep 5

if [ "$RUN_FFMPEG" = "1" ]; then
  echo "Starting FFmpeg capture → $RTSP_URL"
  # If RTSP_LISTEN=1, run FFmpeg as an RTSP server (listening on the given URL)
  FFMPEG_RTSP_OPTS=()
  if [ "$RTSP_LISTEN" = "1" ]; then
    FFMPEG_RTSP_OPTS+=(-rtsp_flags listen)
  fi
  exec ffmpeg -f x11grab -framerate 60 -video_size 1920x1080 -i :0 \
    -vcodec libx264 -preset veryfast -tune zerolatency \
    -pix_fmt yuv420p -rtsp_transport tcp "${FFMPEG_RTSP_OPTS[@]}" -an -f rtsp "$RTSP_URL"
else
  echo "FFmpeg disabled (RUN_FFMPEG=0). Container will stay alive for VNC debugging."
  tail -f /dev/null
fi
