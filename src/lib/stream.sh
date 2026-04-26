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
    # Resolve the actual default source at run time. We can't hard-code
    # "${pulse_sink}.monitor" because Pulse may have fallen back to its
    # own auto_null sink (e.g. our null-sink module-load failed). The
    # default source is whatever pulse considers active for capture,
    # which is normally the default sink's monitor.
    local pulse_source
    if command -v get_default_source >/dev/null 2>&1; then
      pulse_source=$(get_default_source)
    else
      pulse_source=$(pactl info 2>/dev/null | awk -F': ' '/^Default Source/{print $2}')
    fi
    if [ -z "$pulse_source" ]; then
      warn "  no PulseAudio default source — falling back to ${pulse_sink}.monitor"
      pulse_source="${pulse_sink}.monitor"
    fi
    log "  audio source: $pulse_source"
    log "  pulse sink-inputs (apps writing audio):"
    pactl list short sink-inputs 2>/dev/null | sed 's/^/    /' || true
    # Conventional form: inputs first, named muxer last. Some
    # mpegtsmux builds choke on forward-referenced muxer-then-inputs.
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
        ! avenc_aac bitrate=128000 \
        ! aacparse \
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
