#!/usr/bin/env bash
# GStreamer pipelines: live capture (SRT to MediaMTX) and demo recorder (mp4).

# Capture the X display + (optional) PulseAudio monitor and push as MPEG-TS
# over SRT to MediaMTX. EXEC's gst-launch — replaces the calling process.
# Usage: capture_to_srt <streamid>
capture_to_srt() {
  local streamid="$1"
  local url="${MEDIAMTX_SRT_BASE}?streamid=publish:${streamid}"
  local gop=$(( FPS * 2 ))

  log "publishing SRT (audio=$AUDIO): $url"

  if [ "$AUDIO" = "pulse" ] && pgrep -x pulseaudio >/dev/null 2>&1; then
    exec gst-launch-1.0 -e \
      ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer=false \
        ! video/x-raw,framerate="$FPS"/1 \
        ! videoconvert ! video/x-raw,format=NV12 \
        ! nvh264enc preset=low-latency-hq gop-size="$gop" bitrate="$VIDEO_KBPS" rc-mode=cbr \
        ! h264parse config-interval=1 \
        ! mpegtsmux alignment=7 name=mux \
        ! srtsink uri="$url" latency=200 \
      pulsesrc device=cs2.monitor \
        ! audioconvert ! audioresample \
        ! avenc_aac bitrate=$(( AUDIO_KBPS * 1000 )) \
        ! aacparse ! mux.
  else
    exec gst-launch-1.0 -e \
      ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer=false \
        ! video/x-raw,framerate="$FPS"/1 \
        ! videoconvert ! video/x-raw,format=NV12 \
        ! nvh264enc preset=low-latency-hq gop-size="$gop" bitrate="$VIDEO_KBPS" rc-mode=cbr \
        ! h264parse config-interval=1 \
        ! mpegtsmux alignment=7 \
        ! srtsink uri="$url" latency=200
  fi
}

# Record N seconds of the X display to an mp4 file. Blocks until done.
# Usage: record_to_mp4 <output-path> <duration-seconds>
record_to_mp4() {
  local out="$1"
  local seconds="$2"
  local gop=$(( FPS * 2 ))
  local frames=$(( seconds * FPS ))

  log "recording ${seconds}s (${frames} frames) -> $out"
  mkdir -p "$(dirname "$out")"

  gst-launch-1.0 -e \
    ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer=false \
        num-buffers="$frames" \
      ! video/x-raw,framerate="$FPS"/1 \
      ! videoconvert ! video/x-raw,format=NV12 \
      ! nvh264enc preset=hq gop-size="$gop" bitrate="$VIDEO_KBPS" rc-mode=cbr \
      ! h264parse \
      ! mp4mux faststart=true \
      ! filesink location="$out"
}
