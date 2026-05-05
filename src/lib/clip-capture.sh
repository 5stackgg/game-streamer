# shellcheck shell=bash
# clip-capture.sh — file-output GStreamer pipeline for the render-clip
# flow. Mirrors stream.sh's start_capture but writes to a local mp4 via
# qtmux + filesink instead of publishing to mediamtx via mpegtsmux +
# srtsink. Same nvh264enc/x264enc encoder choice rules; we don't need
# low-latency tuning here since the consumer is the file writer not a
# realtime viewer, but matching the live encoder keeps a single GPU
# code path warm.
#
# Why a separate function instead of overloading start_capture: the
# pipeline tail differs (mux + sink) and start_capture's stream_id /
# url derivation is tied to the publish:* convention. Keeping them
# split avoids growing start_capture's argument list past the point
# of readability — it's already a 5-arg function.

# start_clip_capture <output-file> [fps] [video-kbps] [audio]
#
# Captures the X display + cs2 audio sink monitor to <output-file>.
# Returns immediately on success with $SPAWNED_PID set to the gst
# process pid; caller is responsible for stopping it (kill on the
# pid → -e EOS → qtmux finalizes the moov atom). Pipeline writes a
# faststart-friendly mp4 (moov at the front) so the api can stream the
# upload to S3 without buffering the whole file.
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

  # Encoder: prefer the GPU path for parity with the live capture.
  # nvh264enc on the GPU pod, x264enc as fallback for non-GPU debug
  # rigs. crf-style tuning isn't exposed on nvh264enc — bitrate at
  # 8mbps gives clean 1080p60 for short clips without ballooning
  # filesize. mp4 is `qtmux faststart=true` so the moov atom lives at
  # the head of the file; this is what lets the api stream the file
  # straight through to S3 (no second pass needed).
  local enc=""
  if gst-inspect-1.0 nvh264enc >/dev/null 2>&1; then
    enc="nvh264enc preset=hq gop-size=$gop bitrate=$kbps rc-mode=cbr"
  else
    enc="x264enc tune=zerolatency speed-preset=veryfast bitrate=$kbps key-int-max=$gop"
  fi

  log "  clip capture: $out_file (${fps}fps, ${kbps}kbps, audio=$audio)"

  if [ "$audio" = "1" ]; then
    spawn_logged "$gst_tag" gst-launch-1.0 -e \
      ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer=false \
        ! video/x-raw,framerate="$fps"/1 \
        ! videoconvert ! video/x-raw,format=NV12 \
        ! $enc \
        ! h264parse config-interval=1 \
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
        ! h264parse config-interval=1 \
        ! qtmux faststart=true \
        ! filesink location="$out_file"
  fi

  local pid=$SPAWNED_PID
  # Shortened from 3×1s to a single 0.3s probe. We previously held
  # for 3s before returning, which meant the caller couldn't unpause
  # the demo for those 3s — and gst was already in PLAYING state,
  # so the captured mp4 opened with 3 full seconds of frozen frame
  # before any motion. ximagesrc's spawn → PLAYING transition is
  # typically <300ms, so the shorter probe still catches immediate
  # failures (display lost, encoder unavailable). Mid-render deaths
  # are caught by the segment loop's per-second `kill -0` poll, so
  # we don't need a long wall here either.
  sleep 0.3
  if ! kill -0 "$pid" 2>/dev/null; then
    warn "clip capture died on spawn (see [$gst_tag] log lines above)"
    return 1
  fi
  CLIP_CAPTURE_PID=$pid
  log "  clip capture pid=$pid (alive after 0.3s)"
  return 0
}

# stop_clip_capture — graceful EOS so qtmux finalises moov atom.
# Sending SIGINT triggers gst's `-e` flag (already set on launch) to
# emit EOS down the pipeline; without that, killing with SIGTERM
# leaves a truncated mp4 with no moov.
stop_clip_capture() {
  local pid="${CLIP_CAPTURE_PID:-}"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    log "no clip capture running"
    return 0
  fi
  log "stopping clip capture (pid $pid) — graceful EOS"
  kill -INT "$pid" 2>/dev/null || true
  # Wait up to 15s for qtmux to finish writing moov.
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
