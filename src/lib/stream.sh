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
  local pulse_sink="${PULSE_SINK_NAME:-cs2}"
  # gst-launch tag for the k8s log: gst-<short-id> so multiple
  # parallel captures (debug stream + match stream) don't blur together.
  local gst_tag="gst-${stream_id:0:8}"

  if stream_running "$stream_id"; then
    log "capture '${stream_id}' already running (pid $(stream_pid "$stream_id"))"
    return 0
  fi

  log "starting capture '${stream_id}' (fps=$fps kbps=$kbps pointer=$pointer audio=$audio)"
  log "  -> $url"

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
    spawn_logged "$gst_tag" gst-launch-1.0 -e \
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
        ! srtsink uri="$url" latency=200
  else
    spawn_logged "$gst_tag" gst-launch-1.0 -e \
      ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer="$pointer" \
        ! video/x-raw,framerate="$fps"/1 \
        ! videoconvert ! video/x-raw,format=NV12 \
        ! nvh264enc preset=low-latency-hq gop-size="$gop" bitrate="$kbps" rc-mode=cbr \
        ! h264parse config-interval=1 \
        ! mpegtsmux alignment=7 \
        ! srtsink uri="$url" latency=200
  fi

  local pid=$SPAWNED_PID
  # Liveness check: process must survive pipeline negotiation (pulse
  # sources, nvh264enc init, srt handshake). 3s is enough in practice;
  # the WhepPlayer's own retry on the web side surfaces any later
  # publish failures, so we don't need a long bake here.
  local i
  for i in 1 2 3; do
    if ! kill -0 "$pid" 2>/dev/null; then
      warn "capture '${stream_id}' died after ${i}s (see [$gst_tag] log lines above)"
      return 1
    fi
    sleep 1
  done
  log "  pid=$pid (alive after 3s — pipeline negotiated)"

  # Phase 2 (publish-verify) was here. Removed — the polled
  # /v3/paths/get response shape doesn't always match what we
  # checked, and the WhepPlayer's WHEP retry on the web side already
  # surfaces real publish failures. False-negative warnings were
  # chasing problems that didn't exist. If you do need to verify
  # mediamtx is receiving bytes for a stream id, hit:
  #   curl ${MEDIAMTX_API_BASE}/v3/paths/list
  # from inside the pod.
  return 0
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
