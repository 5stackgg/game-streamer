# shellcheck shell=bash
# Helpers for the cs2 spectator-control HTTP daemon (src/spec-server.mjs).
#
# All ops idempotent.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${SPEC_SERVER_PORT:=1350}"
: "${SPEC_SERVER_BIN:=$SRC_DIR/spec-server.mjs}"
export SPEC_SERVER_PORT SPEC_SERVER_BIN

spec_server_running() {
  pgrep -f "[s]pec-server.mjs" >/dev/null 2>&1
}

start_spec_server() {
  if [ ! -f "$SPEC_SERVER_BIN" ]; then
    warn "spec-server not found at $SPEC_SERVER_BIN — skipping"
    return 1
  fi
  if ! command -v node >/dev/null 2>&1; then
    warn "node binary not found in PATH — spec-server requires Node.js"
    return 1
  fi
  if spec_server_running; then
    log "spec-server already running (pid $(pgrep -f '[s]pec-server.mjs' | head -1))"
    return 0
  fi
  log "starting spec-server on :$SPEC_SERVER_PORT (log: $LOG_DIR/spec-server.log)"
  SPEC_PORT="$SPEC_SERVER_PORT" \
    nohup node "$SPEC_SERVER_BIN" \
      >"$LOG_DIR/spec-server.log" 2>&1 &
  log "  spec-server pid=$!"
}

stop_spec_server() {
  pkill -f "[s]pec-server.mjs" 2>/dev/null || true
}

spec_server_status() {
  log "spec-server status:"
  if spec_server_running; then
    log "  process: running (pid $(pgrep -f '[s]pec-server.mjs' | head -1))"
  else
    log "  process: NOT running"
  fi
  local code
  code=$(curl -sS -o /dev/null --max-time 2 -w '%{http_code}' \
    "http://127.0.0.1:${SPEC_SERVER_PORT}/health" 2>/dev/null)
  if [ "$code" = "200" ]; then
    log "  health:  OK on :$SPEC_SERVER_PORT"
    curl -sS --max-time 2 "http://127.0.0.1:${SPEC_SERVER_PORT}/health" 2>/dev/null \
      | sed 's/^/    /'
  else
    log "  health:  unreachable (curl status: ${code:-no response})"
  fi
}
