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
# mediamtx HTTP control API. start_capture polls this to verify a
# publish actually landed (gst-launch happily loops on a failing srt
# sink without crashing — without this poll we'd report status=live
# while no bytes are reaching mediamtx).
: "${MEDIAMTX_API_BASE:=http://mediamtx.5stack.svc.cluster.local:9997}"
# Local scratch dir. Despite the name it's NOT for log files anymore —
# k8s captures the pod's stdout/stderr and that's where logs live.
# This directory holds non-log state shared between subshells:
#   - status.state / status.last / status.boot.epoch (status reporter)
#   - openhud-seed-match.json, spec-bindings.json, demo-round-ticks.json
#   - match-cfgs-prepared / match-cfgs-failed marker files
#   - PID files
# Keeping the LOG_DIR name to avoid mass-renames; treat it as STATE_DIR.
: "${LOG_DIR:=/tmp/game-streamer}"
# Xorg's setuid wrapper (Xwrapper) accepts only a BARE filename for
# -config, not an absolute path. The Dockerfile drops the file into
# /etc/X11/, which Xorg searches. Anyone overriding this must put a file
# named XORG_CONFIG into Xorg's search path themselves.
: "${XORG_CONFIG:=xorg-dummy.conf}"
# CS2 graphics preset — per-pod tunable. Picks resources/video/<preset>.txt,
# copied to $CS2_DIR/game/csgo/cfg/cs2_video.txt before launch. Validated
# by apply_cs2_video_preset in cs2-perf.sh. Orthogonal to the autoexec
# convar block in cs2_perf_autoexec_block (which is the actual source of
# truth for low quality today — the .txt files are stubs).
: "${CS2_GRAPHICS_PRESET:=low}"
mkdir -p "$LOG_DIR" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

export DISPLAY XDG_RUNTIME_DIR STEAM_HOME STEAM_LIBRARY CS2_DIR \
       MEDIAMTX_SRT_BASE MEDIAMTX_API_BASE LOG_DIR XORG_CONFIG \
       CS2_GRAPHICS_PRESET


say()  { printf '\n=== %s ===\n' "$*"; }
log()  { printf '[%s] %s\n' "${SCRIPT_TAG:-game-streamer}" "$*"; }
warn() { printf '[%s] WARN: %s\n' "${SCRIPT_TAG:-game-streamer}" "$*" >&2; }
die()  {
  printf '[%s] ERROR: %s\n' "${SCRIPT_TAG:-game-streamer}" "$*" >&2
  # If the status-reporter is loaded, surface the failure to the API
  # before exiting so the match_streams row reflects status=errored.
  # Tolerate the function being absent (early boot before it's sourced)
  # or unconfigured (no API_BASE) — neither should mask the real error.
  if declare -F report_status >/dev/null 2>&1; then
    report_status status=errored "error=$*" >/dev/null 2>&1 || true
    # Give the daemon one poll cycle to pick up + POST the errored
    # state. The Job will be torn down by stopLive shortly after this
    # exit; without a brief pause the daemon never sees the new state.
    sleep "${STATUS_DIE_FLUSH_SECONDS:-3}" 2>/dev/null || true
  fi
  exit 1
}

# Print a command on stderr before running it. Use for any non-trivial
# external invocation so the operator can copy/paste it for debugging.
run() {
  printf '[%s] $ %s\n' "${SCRIPT_TAG:-game-streamer}" "$*" >&2
  "$@"
}

# Spawn a long-running daemon. Stdout+stderr stream to this process's
# stderr with a "[<tag>] " prefix on every line so k8s container logs
# are self-describing without separate log files. Sets SPAWNED_PID to
# the daemon's pid (NOT the awk pipeline's). nohup detaches the daemon
# from the launcher's controlling tty so HUP doesn't kill it when
# setup-steam → run-live hands off.
#
# The awk subprocess inherits fd 2 from this shell, which in turn
# inherits from the k8s container's stderr — so even after the
# launcher script exits, the awk reparents to PID 1 and keeps tagging
# until the daemon closes its stdout. fflush() keeps the latency low.
spawn_logged() {
  local tag="$1"; shift
  nohup "$@" \
    > >(awk -v t="$tag" '{print "["t"] " $0; fflush()}' >&2) \
    2>&1 &
  SPAWNED_PID=$!
}

# Legacy: callers used to redirect daemon output to "$LOG_DIR/foo.log"
# and dump_log it on failure. Now everything streams to the k8s log
# directly, so dump_log just emits a hint pointing at `kubectl logs`.
# Kept as a stub so existing callers don't have to change.
dump_log() {
  printf '[%s] (logs: kubectl logs -n 5stack <pod>; legacy ref: %s)\n' \
    "${SCRIPT_TAG:-game-streamer}" "${1:-?}" >&2
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
