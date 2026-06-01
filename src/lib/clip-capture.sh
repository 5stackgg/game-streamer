# shellcheck shell=bash
# File-output GStreamer pipeline for render-clip — mirrors stream.sh
# but writes a local mp4 (qtmux + filesink) instead of publishing.

# start_clip_capture <output-file> [fps] [video-kbps] [audio]
# Sets $CLIP_CAPTURE_PID; stop with stop_clip_capture for clean EOS.
# Dispatches on CLIP_CAPTURE_METHOD:
#   vkcapture — obs-vkcapture Vulkan present-hook (DEFAULT). The layer inside cs2
#               (OBS_VKCAPTURE=1) shares the swapchain over a socket; our
#               vkcapture-consumer feeds it into the NVENC pipeline below. Never
#               touches the X server, so it can't stall cs2's present (the
#               gunfight-stutter fix). Needs nvidia-drm.modeset=1 on the host.
#   ximagesrc — the gstreamer X11-grab pipeline; fallback if vkcapture can't start.
start_clip_capture() {
  local method="${CLIP_CAPTURE_METHOD:-vkcapture}"
  if [ "$method" = "vkcapture" ]; then
    if command -v vkcapture-consumer >/dev/null 2>&1; then
      if _start_clip_capture_vkcapture "$@"; then return 0; fi
      warn "vkcapture capture failed to start — falling back to ximagesrc"
    else
      warn "CLIP_CAPTURE_METHOD=vkcapture but vkcapture-consumer not installed — using ximagesrc"
    fi
  fi
  _start_clip_capture_gst "$@"
}

# vkcapture: feed cs2's Vulkan swapchain (obs-vkcapture layer -> our
# vkcapture-consumer) into the SAME NVENC encode tail as the ximagesrc path. The
# consumer runs a GStreamer pipeline whose source is `appsrc name=vksrc` and pushes
# frames sampled from the shared dmabuf at $fps; encode/scale/mux are byte-for-byte
# the gst path, so output dims, codec selection and audio behave identically. The
# consumer finalizes the mp4 on SIGINT (clean EOS), same contract as stop_clip_capture.
_start_clip_capture_vkcapture() {
  local out_file="${1:?output file required}"
  local fps="${2:-60}"
  local kbps="${3:-16000}"
  local audio="${4:-1}"

  local pulse_source="${PULSE_SINK_NAME:-cs2}.monitor"
  local gop=$((fps * 2))

  local out_w="${CLIP_OUTPUT_DIMS%x*}"
  local out_h="${CLIP_OUTPUT_DIMS#*x}"
  [ -z "$out_w" ] && out_w=1920
  [ -z "$out_h" ] && out_h=1080

  mkdir -p "$(dirname "$out_file")"
  rm -f "$out_file"

  # Codec/encoder selection — identical to _start_clip_capture_gst.
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

  local convert
  convert=$(pick_scale_convert "$out_w" "$out_h" "$fps" "$codec")

  log "  clip capture: $out_file (vkcapture/present-hook -> ${out_w}x${out_h}@${fps}fps, ${kbps}kbps, audio=$audio, codec=$codec)"

  # appsrc (name=vksrc) is filled by the consumer from cs2's swapchain; everything
  # downstream matches the ximagesrc path. qtmux faststart=true keeps moov first.
  # videorate + framerate caps -> exact CFR (appsrc frames are stamped on the live
  # clock by do-timestamp, so timing can wobble; videorate dups/drops to lock $fps).
  local vsrc="appsrc name=vksrc ! queue ! videorate ! video/x-raw,framerate=$fps/1"
  local pipeline
  if [ "$audio" = "1" ]; then
    pipeline="$vsrc ! $convert ! $enc ! $parse_caps ! queue ! mux. \
pulsesrc device=$pulse_source ! audio/x-raw,rate=48000,channels=2 ! audioconvert ! audioresample ! avenc_aac bitrate=192000 ! aacparse ! queue ! mux. \
qtmux faststart=true name=mux ! filesink location=$out_file"
  else
    pipeline="$vsrc ! $convert ! $enc ! $parse_caps ! qtmux faststart=true ! filesink location=$out_file"
  fi

  export VKCAP_FPS="$fps"
  spawn_logged vkcap-clip vkcapture-consumer "$pipeline"
  local pid=$SPAWNED_PID
  sleep 0.5
  if ! kill -0 "$pid" 2>/dev/null; then
    warn "vkcapture-consumer died on spawn — obs-vkcapture layer not loaded in cs2 (OBS_VKCAPTURE=1 launch option?), nvidia-drm.modeset=1 missing on host, or bad gst pipeline"
    return 1
  fi
  CLIP_CAPTURE_PID=$pid
  return 0
}

# Reads $CLIP_OUTPUT_DIMS from env to scale capture → output dims so
# the produced mp4 is always at the spec'd resolution regardless of
# the X display's native size (the node may run CS2 at 1080p or 1440p).
_start_clip_capture_gst() {
  local out_file="${1:?output file required}"
  local fps="${2:-60}"
  local kbps="${3:-16000}"
  local audio="${4:-1}"

  local pulse_source="${PULSE_SINK_NAME:-cs2}.monitor"
  local gop=$((fps * 2))
  local gst_tag="gst-clip"

  # Output dims: scale capture to CLIP_OUTPUT_DIMS (e.g. 1920x1080). The
  # chip overlay + outro are rendered/picked at the same dims, so the
  # ffmpeg polish + concat passes downstream don't hit dimension
  # mismatches even when the X display is 1440p.
  local out_w="${CLIP_OUTPUT_DIMS%x*}"
  local out_h="${CLIP_OUTPUT_DIMS#*x}"
  [ -z "$out_w" ] && out_w=1920
  [ -z "$out_h" ] && out_h=1080

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

  log "  clip capture: $out_file (${out_w}x${out_h}@${fps}fps, ${kbps}kbps, audio=$audio, codec=$codec)"

  # GPU scale+convert when the encoder is CUDA-based (see pick_scale_convert).
  local convert
  convert=$(pick_scale_convert "$out_w" "$out_h" "$fps" "$codec")

  # qtmux faststart=true puts moov first so the api streams uploads to S3 without buffering.
  if [ "$audio" = "1" ]; then
    spawn_logged "$gst_tag" gst-launch-1.0 -e \
      ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer=false \
        ! video/x-raw,framerate="$fps"/1 \
        ! $convert \
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
        ! $convert \
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
