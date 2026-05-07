# shellcheck shell=bash
# clip-capture.sh — file-output GStreamer pipeline for the render-clip
# flow. Mirrors stream.sh's start_capture but writes to a local mp4 via
# qtmux + filesink instead of publishing to mediamtx via mpegtsmux +
# srtsink. Shares the same NVENC encoder pickers (pick_h265_pipeline /
# pick_h264_pipeline) as the live capture; we don't need low-latency
# tuning here since the consumer is the file writer not a realtime
# viewer, but matching the live encoder keeps a single GPU code path
# warm.
#
# Why a separate function instead of overloading start_capture: the
# pipeline tail differs (mux + sink) and start_capture's stream_id /
# url derivation is tied to the publish:* convention. Keeping them
# split avoids growing start_capture's argument list past the point
# of readability — it's already a 5-arg function.

# start_clip_capture <output-file> [fps] [video-kbps] [audio]
# Returns immediately with $CLIP_CAPTURE_PID set to the gst pid;
# caller stops it via stop_clip_capture (graceful EOS so qtmux can
# finalize the moov atom).
start_clip_capture() {
  local out_file="${1:?output file required}"
  local fps="${2:-60}"
  local kbps="${3:-8000}"
  local audio="${4:-1}"

  local pulse_source="${PULSE_SINK_NAME:-cs2}.monitor"
  local gop=$((fps * 2))
  local gst_tag="gst-clip"

  mkdir -p "$(dirname "$out_file")"
  rm -f "$out_file"

  # CLIP_VIDEO_CODEC defaults to h265 — NVENC HEVC runs on the same
  # dedicated silicon as h264 (no extra GPU cost) and produces ~30%
  # smaller files at matched quality. The h265 picker scales the kbps
  # internally to reflect HEVC's efficiency, so callers pass a single
  # h264-equivalent bitrate. mp4 needs the hvc1 stream-format tag for
  # Safari/iOS playback (h265parse defaults to byte-stream), forced via
  # capsfilter before qtmux.
  #
  # When called inside the inline-clip-render flow, that script does an
  # upfront coordinated probe and downgrades CLIP_VIDEO_CODEC to h264 if
  # either side (gst capture or ffmpeg slowdown/concat) lacks NVENC HEVC
  # — so the fallback below is mostly belt-and-suspenders for direct
  # callers. Either way the segment ends up codec-uniform with the
  # ffmpeg passes.
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

  # mp4 uses qtmux faststart=true so the api can stream straight to S3.
  log "  clip capture: $out_file (${fps}fps, ${kbps}kbps, audio=$audio, codec=$codec)"

  # qtmux faststart=true puts moov at the front so the api can stream
  # the upload straight to S3 without buffering the whole file.
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
  # 300ms catches spawn failures (display lost, encoder unavailable).
  # The segment loop's per-second kill -0 catches mid-render deaths.
  # Holding longer here meant the captured mp4 opened with N seconds of
  # frozen frame before any motion.
  sleep 0.3
  if ! kill -0 "$pid" 2>/dev/null; then
    warn "clip capture died on spawn"
    return 1
  fi
  CLIP_CAPTURE_PID=$pid
  return 0
}

# SIGINT triggers gst's -e flag (set on launch) to emit EOS down the
# pipeline so qtmux finalises moov. SIGTERM leaves a truncated mp4.
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
