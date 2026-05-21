# shellcheck shell=bash
# Periodic JPEG snapshots of the X display while a live match is being
# captured. No sidecar — runs as a background bash loop inside this pod,
# grabbing one frame from the SAME $DISPLAY ximagesrc the live encoder
# already reads. mediamtx has no built-in snapshot endpoint, so we
# produce the thumbnail in the producer pod and post it to the api,
# which caches it briefly in Redis for any web client to fetch.
#
# Tunables (env, all optional):
#   SNAPSHOT_INTERVAL_SECONDS  cadence between captures (default 30)
#   SNAPSHOT_WIDTH             output JPEG width   (default 640)
#   SNAPSHOT_HEIGHT            output JPEG height  (default 360)
#   SNAPSHOT_QUALITY           jpegenc quality 0-100 (default 70)
#
# Auth: x-origin-auth: ${MATCH_ID}:${MATCH_PASSWORD} — same shape as
# status-reporter, so MATCH_PASSWORD is already populated by the time
# run-live.sh sources us.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${STATUS_API_BASE:=http://api:5585}"
: "${SNAPSHOT_INTERVAL_SECONDS:=30}"
: "${SNAPSHOT_WIDTH:=640}"
: "${SNAPSHOT_HEIGHT:=360}"
: "${SNAPSHOT_QUALITY:=70}"
: "${SNAPSHOT_PID_FILE:=$LOG_DIR/snapshot.pid}"
: "${SNAPSHOT_FILE:=$LOG_DIR/snapshot.jpg}"
: "${SNAPSHOT_INITIAL_DELAY_SECONDS:=5}"

# One-shot frame grab via gst-launch num-buffers=1 — independent of the
# live encode pipeline, so a hiccup here can't drop the broadcast.
_snapshot_capture_one() {
  local out="$1"
  local tmp="${out}.tmp.$$"
  if gst-launch-1.0 -q \
       ximagesrc display-name="$DISPLAY" use-damage=0 num-buffers=1 show-pointer=false \
       ! videoconvert \
       ! videoscale method=lanczos \
       ! "video/x-raw,width=${SNAPSHOT_WIDTH},height=${SNAPSHOT_HEIGHT}" \
       ! jpegenc quality="${SNAPSHOT_QUALITY}" \
       ! filesink location="$tmp" \
       >/dev/null 2>&1
  then
    mv -f "$tmp" "$out"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

_snapshot_upload() {
  local file="$1"
  [ -s "$file" ] || return 1

  if [ -z "${MATCH_ID:-}" ] || [ -z "${MATCH_PASSWORD:-}" ]; then
    return 1
  fi

  local url="${STATUS_API_BASE}/game-streamer/${MATCH_ID}/snapshot"
  local auth="${MATCH_ID}:${MATCH_PASSWORD}"

  local http_code
  http_code=$(curl -sS -m 10 -X POST \
    -H "x-origin-auth: ${auth}" \
    -F "file=@${file};type=image/jpeg" \
    -o /dev/null \
    -w '%{http_code}' \
    "$url" 2>/dev/null) || http_code=""

  case "$http_code" in
    2*) return 0 ;;
    *)
      warn "snapshot upload failed: http=${http_code:-<none>}"
      return 1
      ;;
  esac
}

_snapshot_loop() {
  # Warm-up: cs2 needs to paint a frame before the first snapshot,
  # otherwise the thumbnail is a black loading screen.
  sleep "$SNAPSHOT_INITIAL_DELAY_SECONDS"

  local start sleep_for
  while :; do
    start=$(date +%s)
    if _snapshot_capture_one "$SNAPSHOT_FILE"; then
      _snapshot_upload "$SNAPSHOT_FILE" || true
    else
      warn "snapshot capture failed"
    fi
    local elapsed=$(( $(date +%s) - start ))
    sleep_for=$(( SNAPSHOT_INTERVAL_SECONDS - elapsed ))
    [ "$sleep_for" -lt 1 ] && sleep_for=1
    sleep "$sleep_for"
  done
}

snapshot_running() {
  local pid
  [ -f "$SNAPSHOT_PID_FILE" ] || return 1
  pid=$(cat "$SNAPSHOT_PID_FILE" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

start_snapshot_loop() {
  if [ -z "${MATCH_ID:-}" ] || [ -z "${MATCH_PASSWORD:-}" ]; then
    log "snapshot: disabled (MATCH_ID/MATCH_PASSWORD unset)"
    return 0
  fi
  if snapshot_running; then
    return 0
  fi
  _snapshot_loop &
  echo $! >"$SNAPSHOT_PID_FILE"
  log "snapshot: started (interval=${SNAPSHOT_INTERVAL_SECONDS}s ${SNAPSHOT_WIDTH}x${SNAPSHOT_HEIGHT} q=${SNAPSHOT_QUALITY})"
}

stop_snapshot_loop() {
  local pid
  if [ -f "$SNAPSHOT_PID_FILE" ]; then
    pid=$(cat "$SNAPSHOT_PID_FILE" 2>/dev/null) || true
    rm -f "$SNAPSHOT_PID_FILE"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  fi
}
