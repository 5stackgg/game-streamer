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
# Exported so child processes (e.g. spec-server.mjs) inherit it —
# without `export`, the default only lives in this shell and Node
# sees no STATUS_API_BASE / API_BASE.
: "${STATUS_API_BASE:=http://api:5585}"
export STATUS_API_BASE

# Override path: when STATUS_REPORT_URL + STATUS_AUTH_TOKEN are set, the
# reporter uses them directly and ignores MATCH_ID / MATCH_PASSWORD. Used
# by run-demo.sh, which has a per-user session id + token instead of a
# match password — and posts to /demo-sessions/:id/status, not the
# live-match status endpoint.
: "${STATUS_REPORT_URL:=}"
: "${STATUS_AUTH_TOKEN:=}"

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
: "${STATUS_POLL_SECONDS:=2}"

# Auto-promote demo-session env to the override channel. Both setup-steam.sh
# and run-demo.sh start the reporter, but only run-demo.sh used to set
# the override explicitly — setup-steam.sh would see no MATCH_PASSWORD
# and disable the reporter, losing all status updates from the
# launching-steam / logging-in / downloading-cs2 stages. Doing the
# promotion at config-check time means whichever script calls first
# gets the right wiring.
_promote_demo_session_env() {
  if [ -z "$STATUS_REPORT_URL" ] \
     && [ -n "${DEMO_SESSION_ID:-}" ] \
     && [ -n "${DEMO_SESSION_TOKEN:-}" ]; then
    export STATUS_REPORT_URL="${STATUS_API_BASE}/demo-sessions/${DEMO_SESSION_ID}/status"
    export STATUS_AUTH_TOKEN="${DEMO_SESSION_ID}:${DEMO_SESSION_TOKEN}"
  fi
}

_status_reporter_configured() {
  _promote_demo_session_env
  if [ -n "$STATUS_REPORT_URL" ] && [ -n "$STATUS_AUTH_TOKEN" ]; then
    return 0
  fi
  [ -n "$MATCH_ID" ] && [ -n "$MATCH_PASSWORD" ]
}

# Resolve the destination URL + x-origin-auth value for the daemon.
# Override path wins; the live-match path is the fallback.
_status_report_url() {
  if [ -n "$STATUS_REPORT_URL" ]; then
    printf '%s' "$STATUS_REPORT_URL"
  else
    printf '%s/game-streamer/%s/status' "$STATUS_API_BASE" "$MATCH_ID"
  fi
}
_status_auth_header() {
  if [ -n "$STATUS_AUTH_TOKEN" ]; then
    printf '%s' "$STATUS_AUTH_TOKEN"
  else
    printf '%s:%s' "$MATCH_ID" "$MATCH_PASSWORD"
  fi
}

# Tracks how long each status stage takes. We log "status=X (prev=Y took
# Ns)" on every change, plus a "since boot" cumulative timer, so cold-vs
# warm boots are diagnosable from the pod log without correlating
# timestamps. State files (not bash vars) because callers run in
# subshells: e.g. setup-steam.sh and run-live.sh both call report_status
# from different shell processes that share the same $LOG_DIR.
: "${STATUS_BOOT_FILE:=$LOG_DIR/status.boot.epoch}"
: "${STATUS_LAST_FILE:=$LOG_DIR/status.last}"

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
  # Pull out the status= arg (if any) for the duration log line. Other
  # fields (stream_url, error_message, ...) we don't time.
  local arg new_status=""
  for arg in "$@"; do
    case "$arg" in
      status=*) new_status="${arg#status=}";;
    esac
  done
  if [ -n "$new_status" ]; then
    local now prev_status="" prev_at="" boot_at=""
    now=$(date +%s)
    [ -f "$STATUS_BOOT_FILE" ] || echo "$now" >"$STATUS_BOOT_FILE"
    boot_at=$(cat "$STATUS_BOOT_FILE" 2>/dev/null)
    if [ -f "$STATUS_LAST_FILE" ]; then
      IFS='|' read -r prev_status prev_at <"$STATUS_LAST_FILE" || true
    fi
    if [ -n "$prev_status" ] && [ "$prev_status" != "$new_status" ]; then
      local delta=$(( now - prev_at ))
      local total=$(( now - boot_at ))
      log "status=$new_status (prev=$prev_status took ${delta}s, +${total}s since boot)"
    elif [ -z "$prev_status" ]; then
      log "status=$new_status (first status report)"
    fi
    printf '%s|%s\n' "$new_status" "$now" >"$STATUS_LAST_FILE"
  fi
  local tmp="$STATUS_STATE_FILE.tmp.$$"
  if ! python3 - "$@" >"$tmp" <<'PY'
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
  local last_hash="" current_hash url auth body http_code curl_stderr
  url=$(_status_report_url)
  auth=$(_status_auth_header)
  while :; do
    if [ -f "$STATUS_STATE_FILE" ]; then
      current_hash=$(sha256sum <"$STATUS_STATE_FILE" 2>/dev/null | awk '{print $1}')
      if [ -n "$current_hash" ] && [ "$current_hash" != "$last_hash" ]; then
        body=$(cat "$STATUS_STATE_FILE")
        # Capture stderr (DNS / TLS / refused) into a var so failures
        # surface inline without a temp file. -o /dev/null discards the
        # response body — we only care about the HTTP code for retry.
        curl_stderr=$(curl -sS -m 5 -X POST \
            -H "x-origin-auth: ${auth}" \
            -H "Content-Type: application/json" \
            --data-binary @"$STATUS_STATE_FILE" \
            -o /dev/null \
            -w '%{http_code}' \
            "$url" 2>&1) || true
        # The HTTP code is the LAST line of curl's combined output
        # (curl writes its own stderr first, then -w on stdout).
        http_code="${curl_stderr##*$'\n'}"
        case "$http_code" in
          2*)
            last_hash="$current_hash"
            printf '[status-reporter] %s -> %s\n' "$body" "$http_code" >&2
            ;;
          *)
            # Strip the trailing http_code line for the diagnostic.
            local diag="${curl_stderr%$'\n'*}"
            [ "$diag" = "$curl_stderr" ] && diag=""
            printf '[status-reporter] FAILED %s -> http=%s%s\n' \
              "$body" "${http_code:-<none>}" \
              "$( [ -n "$diag" ] && printf ' (%s)' "$(tr '\n' ' ' <<<"$diag")" )" \
              >&2
            ;;
        esac
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
