# shellcheck shell=bash
# File-output GStreamer pipeline for render-clip — mirrors stream.sh
# but writes a local mp4 (qtmux + filesink) instead of publishing.

# start_clip_capture <output-file> [fps] [video-kbps] [audio]
# Sets $CLIP_CAPTURE_PID; stop with stop_clip_capture for clean EOS.
start_clip_capture() {
  local out_file="${1:?output file required}"
  local fps="${2:-60}"
  local kbps="${3:-16000}"
  local audio="${4:-1}"

  local pulse_source="${PULSE_SINK_NAME:-cs2}.monitor"
  local gop=$((fps * 2))
  local gst_tag="gst-clip"

  mkdir -p "$(dirname "$out_file")"
  rm -f "$out_file"

  # CLIP_VIDEO_CODEC=h265|h264 (default h265, falls back to h264 if no NVENC HEVC).
  # hvc1 tag is required for mp4 / Safari / iOS playback.
  local codec="${CLIP_VIDEO_CODEC:-h265}"
  local enc="" parse_caps=""
  case "$codec" in
    h265|hevc)
      if enc=$(pick_h265_pipeline "$gop" "$kbps" clip); then
        parse_caps="h265parse config-interval=1 ! video/x-h265,stream-format=hvc1,alignment=au"
      else
        warn "CLIP_VIDEO_CODEC=$codec but no NVENC HEVC encoder available — falling back to h264"
        codec="h264"
      fi
      ;;
    h264) : ;;
    *)
      warn "CLIP_VIDEO_CODEC=$codec unrecognized — using h264"
      codec="h264"
      ;;
  esac
  if [ "$codec" = "h264" ]; then
    enc=$(pick_h264_pipeline "$gop" "$kbps" clip)
    parse_caps="h264parse config-interval=1"
  fi

  log "  clip capture: $out_file (${fps}fps, ${kbps}kbps, audio=$audio, codec=$codec)"

  # qtmux faststart=true puts moov first so the api streams uploads to S3 without buffering.
  if [ "$audio" = "1" ]; then
    spawn_logged "$gst_tag" gst-launch-1.0 -e \
      ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer=false \
        ! video/x-raw,framerate="$fps"/1 \
        ! videoconvert ! video/x-raw,format=NV12 \
        ! $enc \
        ! $parse_caps \
        ! queue ! mux. \
      pulsesrc device="$pulse_source" \
        ! audio/x-raw,rate=48000,channels=2 \
        ! audioconvert \
        ! audioresample \
        ! avenc_aac bitrate=192000 \
        ! aacparse \
        ! queue ! mux. \
      qtmux faststart=true name=mux \
        ! filesink location="$out_file"
  else
    spawn_logged "$gst_tag" gst-launch-1.0 -e \
      ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer=false \
        ! video/x-raw,framerate="$fps"/1 \
        ! videoconvert ! video/x-raw,format=NV12 \
        ! $enc \
        ! $parse_caps \
        ! qtmux faststart=true \
        ! filesink location="$out_file"
  fi

  local pid=$SPAWNED_PID
  # 300ms catches spawn failures; the segment loop catches mid-render deaths.
  # Longer waits add frozen-frame padding at the start of the mp4.
  sleep 0.3
  if ! kill -0 "$pid" 2>/dev/null; then
    warn "clip capture died on spawn"
    return 1
  fi
  CLIP_CAPTURE_PID=$pid
  return 0
}

# SIGINT + gst -e = clean EOS so qtmux finalises moov. SIGTERM truncates.
stop_clip_capture() {
  local pid="${CLIP_CAPTURE_PID:-}"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  kill -INT "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    warn "clip capture didn't exit — forcing"
    kill -9 "$pid" 2>/dev/null || true
  fi
  CLIP_CAPTURE_PID=""
}
