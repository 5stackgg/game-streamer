# shellcheck shell=bash
# GStreamer SRT capture. Tagged by stream-id so we can find/kill specific streams.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

stream_pid() {
  local stream_id="$1"
  pgrep -f "publish:${stream_id}\b" | head -1
}

stream_running() {
  [ -n "$(stream_pid "$1")" ]
}

# start_capture <stream-id> [fps] [video-kbps] [show-pointer] [audio]
#   audio: 1 to include PulseAudio leg (default), 0 video-only
start_capture() {
  local stream_id="${1:?stream-id required}"
  local fps="${2:-30}"
  local kbps="${3:-4000}"
  local pointer="${4:-true}"
  local audio="${5:-${CAPTURE_AUDIO:-1}}"
  local gop=$(( fps * 2 ))
  local url="${MEDIAMTX_SRT_BASE}?streamid=publish:${stream_id}"
  local pulse_sink="${PULSE_SINK_NAME:-cs2}"
  local gst_tag="gst-${stream_id:0:8}"

  if stream_running "$stream_id"; then
    return 0
  fi

  log "starting capture '${stream_id}' (fps=$fps kbps=$kbps audio=$audio) -> $url"

  # LIVE_VIDEO_CODEC defaults to h265 — NVENC HEVC encode is free on
  # GPU and ~30-40% smaller bitrate at matched quality, which is the
  # win on the mediamtx → viewer hop. mediamtx (>=1.x) muxes HEVC into
  # HLS over fMP4 fine; modern Chrome/Edge/Safari/iOS decode in HW.
  # Firefox-on-Linux + older Android viewers may fail to play, surface
  # a "use a different browser" notice in the player UI for those.
  # If NVENC HEVC is unavailable (no GPU / older driver), fall back to
  # h264 so the live stream never goes dark.
  #
  # MPEG-TS does NOT use the hvc1/hev1 codec tag (that's an MP4 thing),
  # so h265parse's default byte-stream output is what mpegtsmux wants
  # — no capsfilter needed here.
  local codec="${LIVE_VIDEO_CODEC:-h265}"
  local enc="" parse=""
  case "$codec" in
    h265|hevc)
      if enc=$(pick_h265_pipeline "$gop" "$kbps" live); then
        parse="h265parse config-interval=1"
      else
        warn "LIVE_VIDEO_CODEC=$codec but no NVENC HEVC encoder available — falling back to h264"
        codec="h264"
      fi
      ;;
    h264) : ;;
    *)
      warn "LIVE_VIDEO_CODEC=$codec unrecognized — using h264"
      codec="h264"
      ;;
  esac
  if [ "$codec" = "h264" ]; then
    enc=$(pick_h264_pipeline "$gop" "$kbps" live)
    parse="h264parse config-interval=1"
  fi
  log "  codec: $codec"

  # Persist args so restart_capture can re-invoke us identically.
  local args_dir="${LOG_DIR:-/tmp/game-streamer}"
  mkdir -p "$args_dir"
  printf '%s\n%s\n%s\n%s\n%s\n' \
    "$stream_id" "$fps" "$kbps" "$pointer" "$audio" \
    > "${args_dir}/capture-${stream_id}.args"

  if [ "$audio" = 1 ]; then
    # Pin to our named null sink's .monitor. Trusting `pactl info`'s
    # default would let hud-manager's Pulse client nudge us off
    # cs2.monitor and onto silence / HUD UI audio.
    local pulse_source="${pulse_sink}.monitor"
    if ! pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx "$pulse_source"; then
      warn "  ${pulse_source} not present — falling back to default source"
      if command -v get_default_source >/dev/null 2>&1; then
        pulse_source=$(get_default_source)
      else
        pulse_source=$(pactl info 2>/dev/null | awk -F': ' '/^Default Source/{print $2}')
      fi
      [ -n "$pulse_source" ] || pulse_source="${pulse_sink}.monitor"
    fi
    # Opus, not AAC: mediamtx forwards Opus straight to WebRTC consumers
    # (browsers decode it natively) without per-viewer ffmpeg transcode.
    # LL-HLS carries Opus fine for modern browsers + Safari 17+.
    spawn_logged "$gst_tag" gst-launch-1.0 -e \
      ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer="$pointer" \
        ! video/x-raw,framerate="$fps"/1 \
        ! videoconvert ! video/x-raw,format=NV12 \
        ! $enc \
        ! $parse \
        ! queue ! mux. \
      pulsesrc device="$pulse_source" \
        ! audio/x-raw,rate=48000,channels=2 \
        ! audioconvert \
        ! audioresample \
        ! opusenc bitrate=128000 \
        ! opusparse \
        ! queue ! mux. \
      mpegtsmux name=mux alignment=7 \
        ! srtsink uri="$url" latency=200
  else
    spawn_logged "$gst_tag" gst-launch-1.0 -e \
      ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer="$pointer" \
        ! video/x-raw,framerate="$fps"/1 \
        ! videoconvert ! video/x-raw,format=NV12 \
        ! $enc \
        ! $parse \
        ! mpegtsmux alignment=7 \
        ! srtsink uri="$url" latency=200
  fi

  # Liveness check — the pipeline must survive negotiation (pulse,
  # nvh264enc init, srt handshake). The WhepPlayer's own retry surfaces
  # later publish failures.
  local pid=$SPAWNED_PID
  local i
  for i in 1 2 3; do
    if ! kill -0 "$pid" 2>/dev/null; then
      warn "capture '${stream_id}' died after ${i}s"
      return 1
    fi
    sleep 1
  done
  return 0
}

restart_capture() {
  local stream_id="${1:?stream-id required}"
  local args_file="${LOG_DIR:-/tmp/game-streamer}/capture-${stream_id}.args"
  if [ ! -f "$args_file" ]; then
    warn "restart_capture: no saved args for '${stream_id}'"
    return 1
  fi
  local sid fps kbps pointer audio
  { read -r sid; read -r fps; read -r kbps; read -r pointer; read -r audio; } < "$args_file"

  stop_capture "$stream_id"
  # Let mediamtx clear the stale publisher before reconnecting.
  sleep 1
  start_capture "$sid" "$fps" "$kbps" "$pointer" "$audio"
}

stop_capture() {
  local stream_id="${1:?stream-id required}"
  local pid
  pid=$(stream_pid "$stream_id") || true
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  fi
}
