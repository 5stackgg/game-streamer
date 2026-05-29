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

  # Output dims: scale capture to LIVE_OUTPUT_DIMS (default 1920x1080).
  # CS2 may render at 1440p natively, but the live HLS stream + HUD
  # overlay CSS + viewer expectations all key off 1080p — and scaling
  # 1440p → 1080p at capture time gives a supersampled 1080p that's
  # crisper than rendering CS2 natively at 1080p.
  local live_out="${LIVE_OUTPUT_DIMS:-1920x1080}"
  local out_w="${live_out%x*}"
  local out_h="${live_out#*x}"
  [ -z "$out_w" ] && out_w=1920
  [ -z "$out_h" ] && out_h=1080
  local scale_caps="video/x-raw,width=${out_w},height=${out_h},framerate=${fps}/1"

  if stream_running "$stream_id"; then
    return 0
  fi

  log "starting capture '${stream_id}' (${out_w}x${out_h}@${fps}fps kbps=$kbps audio=$audio) -> $url"

  # LIVE_VIDEO_CODEC=h265|h264. Default h265 — falls back to h264 if no NVENC HEVC.
  # Note: HEVC-over-WebRTC is Safari 17+ only; non-HEVC browsers fall back to HLS.
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
    # Pin to our named null sink's .monitor — pactl's default can drift
    # to hud-manager's Pulse client / silence.
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
    # Opus: mediamtx forwards straight to WebRTC without per-viewer transcode.
    spawn_logged "$gst_tag" gst-launch-1.0 -e \
      ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer="$pointer" \
        ! video/x-raw,framerate="$fps"/1 \
        ! videoscale ! "$scale_caps" \
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
        ! videoscale ! "$scale_caps" \
        ! videoconvert ! video/x-raw,format=NV12 \
        ! $enc \
        ! $parse \
        ! mpegtsmux alignment=7 \
        ! srtsink uri="$url" latency=200
  fi

  # Liveness check — must survive pulse / NVENC init / srt handshake.
  local pid=$SPAWNED_PID
  local i
  for i in 1 2 3; do
    if ! kill -0 "$pid" 2>/dev/null; then
      warn "capture '${stream_id}' died after ${i}s"
      return 1
    fi
    sleep 1
  done

  # Log the watchable HLS URL (grep "WATCH") for the early/boot phase.
  local dom="${GAME_STREAM_DOMAIN:-hls.5stack.gg}"
  dom="${dom%/}"
  case "$dom" in
    http://*|https://*) ;;
    *) dom="https://$dom" ;;
  esac
  log "WATCH (HLS): ${dom}/${stream_id}/index.m3u8"

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
