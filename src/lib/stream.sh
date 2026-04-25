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

# start_capture <stream-id> [fps] [video-kbps] [show-pointer]
start_capture() {
  local stream_id="${1:?stream-id required}"
  local fps="${2:-30}"
  local kbps="${3:-4000}"
  local pointer="${4:-true}"
  local gop=$(( fps * 2 ))
  local url="${MEDIAMTX_SRT_BASE}?streamid=publish:${stream_id}"
  local logf="$LOG_DIR/gst-${stream_id}.log"

  if stream_running "$stream_id"; then
    log "capture '${stream_id}' already running (pid $(stream_pid "$stream_id"))"
    return 0
  fi

  log "starting capture '${stream_id}' -> $url"
  nohup gst-launch-1.0 -e \
    ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer="$pointer" \
      ! video/x-raw,framerate="$fps"/1 \
      ! videoconvert ! video/x-raw,format=NV12 \
      ! nvh264enc preset=low-latency-hq gop-size="$gop" bitrate="$kbps" rc-mode=cbr \
      ! h264parse config-interval=1 \
      ! mpegtsmux alignment=7 \
      ! srtsink uri="$url" latency=200 \
      >"$logf" 2>&1 &
  local pid=$!
  sleep 2
  if kill -0 "$pid" 2>/dev/null; then
    log "  pid=$pid (log: $logf)"
  else
    warn "capture '${stream_id}' failed to stay up — tail $logf:"
    tail -30 "$logf" >&2 || true
    return 1
  fi
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
