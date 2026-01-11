# shellcheck shell=bash
# GStreamer SRT capture helpers.
# We tag each pipeline by stream-id so we can find/kill specific streams.

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
  local logf="$LOG_DIR/gst-${stream_id}.log"
  local pulse_sink="${PULSE_SINK_NAME:-cs2}"

  if stream_running "$stream_id"; then
    log "capture '${stream_id}' already running (pid $(stream_pid "$stream_id"))"
    return 0
  fi

  log "starting capture '${stream_id}' (fps=$fps kbps=$kbps pointer=$pointer audio=$audio)"
  log "  -> $url"
  log "  log: $logf"

  if [ "$audio" = 1 ]; then
    # Pin capture to OUR null sink's monitor. We deliberately don't trust
    # `pactl info`'s Default Source here — once OpenHud's Electron started
    # connecting to Pulse it was nudging the default off cs2.monitor and
    # we'd silently capture HUD UI audio (or auto_null silence) instead of
    # the game. Only fall back to whatever's "default" if the named sink's
    # monitor truly doesn't exist (i.e. our module-null-sink load failed
    # and pulse is on auto_null).
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
    log "  audio source: $pulse_source"
    log "  pulse sink-inputs (apps writing audio):"
    pactl list short sink-inputs 2>/dev/null | sed 's/^/    /' || true
    # Conventional form: inputs first, named muxer last. Some
    # mpegtsmux builds choke on forward-referenced muxer-then-inputs.
    # Audio codec: Opus (not AAC). mediamtx forwards Opus directly to
    # WebRTC consumers — browsers natively decode Opus and the SDP
    # offer/answer includes it as a default codec, so the WebRTC track
    # plays without any transcode. AAC over WebRTC would require
    # mediamtx to run ffmpeg per-viewer, which it doesn't do by
    # default — net effect is silent WebRTC playback.
    #
    # HLS impact: LL-HLS uses fMP4 segments (hlsVariant: lowLatency in
    # mediamtx.yml), which carries Opus fine for Chrome/Firefox/Edge
    # and Safari 17+. If you need to support older Safari/iOS, switch
    # back to avenc_aac and configure mediamtx runOnReady to ffmpeg-
    # transcode AAC -> Opus on a sidecar path.
    nohup gst-launch-1.0 -e \
      ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer="$pointer" \
        ! video/x-raw,framerate="$fps"/1 \
        ! videoconvert ! video/x-raw,format=NV12 \
        ! nvh264enc preset=low-latency-hq gop-size="$gop" bitrate="$kbps" rc-mode=cbr \
        ! h264parse config-interval=1 \
        ! queue ! mux. \
      pulsesrc device="$pulse_source" \
        ! audio/x-raw,rate=48000,channels=2 \
        ! audioconvert \
        ! audioresample \
        ! opusenc bitrate=128000 \
        ! opusparse \
        ! queue ! mux. \
      mpegtsmux name=mux alignment=7 \
        ! srtsink uri="$url" latency=200 \
      >"$logf" 2>&1 &
  else
    nohup gst-launch-1.0 -e \
      ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer="$pointer" \
        ! video/x-raw,framerate="$fps"/1 \
        ! videoconvert ! video/x-raw,format=NV12 \
        ! nvh264enc preset=low-latency-hq gop-size="$gop" bitrate="$kbps" rc-mode=cbr \
        ! h264parse config-interval=1 \
        ! mpegtsmux alignment=7 \
        ! srtsink uri="$url" latency=200 \
      >"$logf" 2>&1 &
  fi

  local pid=$!
  # Wait long enough for the pipeline to negotiate caps + open the
  # encoders and muxer. Pulse sources, srt connect, and nvh264enc
  # initialization can each take 2-3 seconds. If the pid is still alive
  # at 5s, the pipeline is genuinely streaming.
  local i
  for i in 1 2 3 4 5; do
    if ! kill -0 "$pid" 2>/dev/null; then
      warn "capture '${stream_id}' died after ${i}s (during pipeline negotiation)"
      dump_log "$logf" 80
      return 1
    fi
    sleep 1
  done
  log "  pid=$pid (alive after 5s — pipeline negotiated)"
}

stop_capture() {
  local stream_id="${1:?stream-id required}"
  local pid
  pid=$(stream_pid "$stream_id") || true
  if [ -n "$pid" ]; then
    log "stopping capture '${stream_id}' (pid $pid)"
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  else
    log "no capture '${stream_id}' running"
  fi
}
