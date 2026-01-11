# shellcheck shell=bash
# Posts streamer-pod status to the 5stack API.
#
# A single background daemon owns the latest desired state and retries
# until the API returns 2xx. report_status() updates the state file
# atomically; the daemon's next loop iteration sees the new content
# (different sha256) and POSTs that — older intermediate states are
# dropped silently. There is no queue.
#
# Endpoint: POST ${STATUS_API_BASE}/game-streamer/${MATCH_ID}/status
# Auth:     x-origin-auth: ${MATCH_ID}:${MATCH_PASSWORD}
# Body:     flat JSON object, e.g. {"status":"live","stream_url":"..."}
#
# No-op (logs once and returns) if MATCH_ID / MATCH_PASSWORD are unset,
# so local runs without an API don't accumulate retry noise.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# In-cluster Service URL of the 5stack API. The streamer pod is always
# scheduled in the same cluster as the api Deployment, so the kube DNS
# short-name resolves on the pod's search domain. Override with
# STATUS_API_BASE for local testing outside the cluster.
: "${STATUS_API_BASE:=http://api:5585}"

: "${MATCH_ID:=}"
: "${MATCH_PASSWORD:=}"

# Fall back to the connect-password env vars the API already injects
# (and that local test runs typically already set on existing matches),
# so the reporter Just Works without a separately-named MATCH_PASSWORD.
#   CONNECT_TV_PASSWORD = raw password (TV port mode)
#   CONNECT_PASSWORD    = "tv:<role>:<password>"  (game-port fallback;
#                         the role segment varies — "user", "streamer",
#                         etc. — so strip a generic tv:<word>: prefix.)
if [ -z "$MATCH_PASSWORD" ]; then
  if [ -n "${CONNECT_TV_PASSWORD:-}" ]; then
    MATCH_PASSWORD="$CONNECT_TV_PASSWORD"
  elif [ -n "${CONNECT_PASSWORD:-}" ]; then
    MATCH_PASSWORD="${CONNECT_PASSWORD#tv:*:}"
  fi
fi
: "${STATUS_STATE_FILE:=$LOG_DIR/status.state}"
: "${STATUS_ACK_FILE:=$LOG_DIR/status.ack}"
: "${STATUS_DAEMON_PID_FILE:=$LOG_DIR/status.daemon.pid}"
: "${STATUS_REPORT_LOG:=$LOG_DIR/status.log}"
: "${STATUS_POLL_SECONDS:=2}"

_status_reporter_configured() {
  [ -n "$MATCH_ID" ] && [ -n "$MATCH_PASSWORD" ]
}

# Write a fresh JSON object to the state file atomically. Argv form is
# key=value (e.g. status=live stream_url=srt://...) — values may contain
# spaces. python3 handles JSON escaping so quoting is correct.
report_status() {
  if ! _status_reporter_configured; then
    return 0
  fi
  if [ "$#" -eq 0 ]; then
    return 0
  fi
  local tmp="$STATUS_STATE_FILE.tmp.$$"
  if ! python3 - "$@" >"$tmp" 2>>"$STATUS_REPORT_LOG" <<'PY'
import json, sys
out = {}
for arg in sys.argv[1:]:
    if "=" not in arg:
        continue
    k, v = arg.split("=", 1)
    out[k] = v
print(json.dumps(out))
PY
  then
    rm -f "$tmp"
    warn "report_status: failed to encode JSON for: $*"
    return 1
  fi
  mv -f "$tmp" "$STATUS_STATE_FILE"
}

_status_daemon_running() {
  local pid
  [ -f "$STATUS_DAEMON_PID_FILE" ] || return 1
  pid=$(cat "$STATUS_DAEMON_PID_FILE" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

_status_daemon_loop() {
  local last_hash="" current_hash url body http_code curl_err
  url="${STATUS_API_BASE}/game-streamer/${MATCH_ID}/status"
  while :; do
    if [ -f "$STATUS_STATE_FILE" ]; then
      current_hash=$(sha256sum <"$STATUS_STATE_FILE" 2>/dev/null | awk '{print $1}')
      if [ -n "$current_hash" ] && [ "$current_hash" != "$last_hash" ]; then
        body=$(cat "$STATUS_STATE_FILE")
        printf '[%s] POST %s body=%s\n' \
          "$(date -u +%FT%TZ)" "$url" "$body" >>"$STATUS_REPORT_LOG"
        # -w prints the HTTP status to stdout AFTER the response body.
        # Capture both so failures reveal whether it was a transport
        # error (no status), auth (401), validation (400), or 5xx.
        curl_err="$STATUS_REPORT_LOG.curl-stderr.$$"
        http_code=$(curl -sS -m 5 -X POST \
            -H "x-origin-auth: ${MATCH_ID}:${MATCH_PASSWORD}" \
            -H "Content-Type: application/json" \
            --data-binary @"$STATUS_STATE_FILE" \
            -o >(tee -a "$STATUS_REPORT_LOG" >/dev/null) \
            -w '%{http_code}' \
            "$url" 2>"$curl_err")
        printf '\n[%s] -> http=%s\n' \
          "$(date -u +%FT%TZ)" "${http_code:-<none>}" >>"$STATUS_REPORT_LOG"
        cat "$curl_err" >>"$STATUS_REPORT_LOG" 2>/dev/null || true
        if [ "${http_code:-0}" -ge 200 ] 2>/dev/null \
           && [ "${http_code:-0}" -lt 300 ] 2>/dev/null; then
          last_hash="$current_hash"
          # Echo successes inline ONCE per state change (already
          # gated by hash) so the operator's terminal shows progress
          # without tailing the log file.
          printf '[status-reporter] %s -> %s\n' "$body" "$http_code" >&2
        else
          # Failures are loud: print the curl stderr alongside the
          # http code so DNS / TLS / connection-refused issues are
          # diagnosable from the live console without spelunking.
          printf '[status-reporter] FAILED %s -> http=%s%s\n' \
            "$body" \
            "${http_code:-<none>}" \
            "$( [ -s "$curl_err" ] && printf ' (%s)' "$(tr '\n' ' ' <"$curl_err")" )" \
            >&2
        fi
        rm -f "$curl_err"
      fi
    fi
    sleep "$STATUS_POLL_SECONDS"
  done
}

# Spawn the daemon if it isn't already running. Idempotent — safe to
# call from setup-steam and run-live both.
start_status_reporter() {
  if ! _status_reporter_configured; then
    log "status-reporter: MATCH_ID/MATCH_PASSWORD unset — disabled"
    return 0
  fi
  if _status_daemon_running; then
    return 0
  fi
  : >"$STATUS_REPORT_LOG"
  rm -f "$STATUS_ACK_FILE"
  _status_daemon_loop &
  echo $! >"$STATUS_DAEMON_PID_FILE"
  log "status-reporter: daemon started (pid $!)"
}

stop_status_reporter() {
  local pid
  if [ -f "$STATUS_DAEMON_PID_FILE" ]; then
    pid=$(cat "$STATUS_DAEMON_PID_FILE" 2>/dev/null) || true
    rm -f "$STATUS_DAEMON_PID_FILE"
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
    fi
  fi
}
