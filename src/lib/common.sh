# shellcheck shell=bash
# Shared helpers for src/ scripts.
# Source this from anywhere under src/; SRC_DIR is resolved from BASH_SOURCE.

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SRC_DIR/lib"
FLOWS_DIR="$SRC_DIR/flows"
export SRC_DIR LIB_DIR FLOWS_DIR

: "${DISPLAY:=:0}"
: "${XDG_RUNTIME_DIR:=/tmp/xdg-runtime-root}"
: "${STEAM_HOME:=/root/.local/share/Steam}"
: "${STEAM_LIBRARY:=/mnt/game-streamer}"
: "${CS2_DIR:=$STEAM_LIBRARY/steamapps/common/Counter-Strike Global Offensive}"
: "${MEDIAMTX_SRT_BASE:=srt://mediamtx.5stack.svc.cluster.local:8890}"
: "${LOG_DIR:=/tmp/game-streamer}"
# Xorg's setuid wrapper (Xwrapper) accepts only a BARE filename for
# -config, not an absolute path. The Dockerfile drops the file into
# /etc/X11/, which Xorg searches. Anyone overriding this must put a file
# named XORG_CONFIG into Xorg's search path themselves.
: "${XORG_CONFIG:=xorg-dummy.conf}"
mkdir -p "$LOG_DIR" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

export DISPLAY XDG_RUNTIME_DIR STEAM_HOME STEAM_LIBRARY CS2_DIR \
       MEDIAMTX_SRT_BASE LOG_DIR XORG_CONFIG


say()  { printf '\n=== %s ===\n' "$*"; }
log()  { printf '[%s] %s\n' "${SCRIPT_TAG:-game-streamer}" "$*"; }
warn() { printf '[%s] WARN: %s\n' "${SCRIPT_TAG:-game-streamer}" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "${SCRIPT_TAG:-game-streamer}" "$*" >&2; exit 1; }

# Print a command on stderr before running it. Use for any non-trivial
# external invocation so the operator can copy/paste it for debugging.
run() {
  printf '[%s] $ %s\n' "${SCRIPT_TAG:-game-streamer}" "$*" >&2
  "$@"
}

# Dump the tail of a log inline (no "see /tmp/whatever" indirection).
dump_log() {
  local f="$1" n="${2:-60}"
  if [ -f "$f" ]; then
    printf '[%s] --- last %s lines of %s ---\n' "${SCRIPT_TAG:-game-streamer}" "$n" "$f" >&2
    tail -n "$n" "$f" | sed 's/^/    /' >&2
    printf '[%s] --- end %s ---\n' "${SCRIPT_TAG:-game-streamer}" "$f" >&2
  else
    printf '[%s] (no log at %s)\n' "${SCRIPT_TAG:-game-streamer}" "$f" >&2
  fi
}

# Trap-friendly verbose toggle. `GS_TRACE=1 ./game-streamer.sh ...` runs
# under `set -x` so every command is echoed.
[ "${GS_TRACE:-0}" = "1" ] && set -x

require_env() {
  local v
  for v in "$@"; do
    [ -n "${!v:-}" ] || die "missing required env: $v"
  done
}

# Load src/.env if present so flows can be invoked without an external wrapper.
load_env() {
  local f="$SRC_DIR/.env"
  if [ -f "$f" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
  fi
}
