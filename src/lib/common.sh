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
: "${GAME_STREAM_DOMAIN:=hls.5stack.gg}"
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
# CS2 fps cap — used by cs2-perf.sh in the autoexec fps_max convar and
# surfaced in the apply_cs2_video_preset log line. 60 keeps the encoder
# pipeline steady; bump per-pod via env if a higher cap is needed.
: "${CS2_FPS_MAX:=60}"
mkdir -p "$LOG_DIR" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

export DISPLAY XDG_RUNTIME_DIR STEAM_HOME STEAM_LIBRARY CS2_DIR \
       MEDIAMTX_SRT_BASE MEDIAMTX_API_BASE GAME_STREAM_DOMAIN \
       LOG_DIR XORG_CONFIG CS2_GRAPHICS_PRESET CS2_FPS_MAX


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

# Pick an H.264 encoder fragment for `! video/x-raw,format=NV12 !`.
# Tries nvcudah264enc, then nvh264enc with a probed preset (driver 550+
# drops legacy preset GUIDs from the enumerated list, so low-latency-hq
# fails strict validation), then x264enc. Result cached per-process in
# GS_NVENC_PICK; override the family with GS_NVENC_ELEMENT.
# Usage: pick_h264_pipeline <gop> <kbps> [live|clip]
pick_h264_pipeline() {
  local gop="${1:?gop required}"
  local kbps="${2:?kbps required}"
  local mode="${3:-live}"

  if [ -z "${GS_NVENC_PICK:-}" ]; then
    GS_NVENC_PICK=$(_resolve_h264_method) || return 1
    export GS_NVENC_PICK
  fi

  case "$GS_NVENC_PICK" in
    nvcudah264enc)
      # Property names on the modern CUDA encoder differ from the legacy
      # nvh264enc: it uses `rate-control` (not `rc-mode`). Using the wrong
      # name dies at pipeline-parse with `no property "rc-mode" in
      # element "nvcudah264enc"`.
      local preset tune
      case "$mode" in
        clip) preset="p5"; tune="high-quality" ;;
        *)    preset="p4"; tune="low-latency"  ;;
      esac
      printf 'cudaupload ! nvcudah264enc preset=%s tune=%s rate-control=cbr gop-size=%s bitrate=%s' \
        "$preset" "$tune" "$gop" "$kbps"
      ;;
    nvh264enc:*)
      local preset="${GS_NVENC_PICK#nvh264enc:}"
      printf 'nvh264enc preset=%s rc-mode=cbr gop-size=%s bitrate=%s' \
        "$preset" "$gop" "$kbps"
      ;;
    x264enc)
      printf 'x264enc tune=zerolatency speed-preset=veryfast bitrate=%s key-int-max=%s' \
        "$kbps" "$gop"
      ;;
  esac
}

_resolve_h264_method() {
  # IMPORTANT: this function is called via $(...) command substitution by
  # pick_h264_pipeline, so its stdout is captured into GS_NVENC_PICK.
  # Any informational `log` lines MUST go to stderr (>&2) — otherwise
  # they get glued onto the encoder name, the case statement in
  # pick_h264_pipeline matches nothing, $enc comes back empty, and the
  # gst-launch pipeline collapses to "... ! ! ..." (syntax error,
  # GST_IS_BIN assertion at the bin-parent link step).
  local force="${GS_NVENC_ELEMENT:-auto}"

  if [ "$force" = "auto" ] || [ "$force" = "nvcudah264enc" ]; then
    if gst-inspect-1.0 nvcudah264enc >/dev/null 2>&1 \
       && gst-inspect-1.0 cudaupload >/dev/null 2>&1 \
       && _probe_nvcudah264enc; then
      log "  encoder: nvcudah264enc (GPU, modern API)" >&2
      printf 'nvcudah264enc'
      return 0
    fi
    [ "$force" = "nvcudah264enc" ] && \
      warn "GS_NVENC_ELEMENT=nvcudah264enc forced but unavailable — falling through"
  fi

  if [ "$force" = "auto" ] || [ "$force" = "nvh264enc" ]; then
    if gst-inspect-1.0 nvh264enc >/dev/null 2>&1; then
      local preset
      if preset=$(_probe_nvh264enc_preset); then
        log "  encoder: nvh264enc preset=$preset (GPU, legacy API)" >&2
        printf 'nvh264enc:%s' "$preset"
        return 0
      fi
    fi
    [ "$force" = "nvh264enc" ] && \
      warn "GS_NVENC_ELEMENT=nvh264enc forced but unavailable — falling through"
  fi

  log "  encoder: x264enc (software fallback)" >&2
  printf 'x264enc'
}

_probe_nvcudah264enc() {
  # Probe with the *same* property surface we'll use in production
  # (rate-control + gop-size + bitrate). If a future GStreamer rev
  # renames or drops one of these, the probe fails and we fall through
  # to nvh264enc/x264enc instead of silently passing here and crashing
  # at real-pipeline parse time mid-match.
  gst-launch-1.0 -q \
    videotestsrc num-buffers=1 \
    ! video/x-raw,format=NV12,width=320,height=240,framerate=30/1 \
    ! cudaupload \
    ! nvcudah264enc preset=p4 tune=low-latency rate-control=cbr gop-size=60 bitrate=2000 \
    ! fakesink sync=false \
    >/dev/null 2>&1
}

_probe_nvh264enc_preset() {
  local p
  for p in ${NVH264_PRESET_CANDIDATES:-low-latency-hq low-latency hq default}; do
    if gst-launch-1.0 -q \
         videotestsrc num-buffers=1 \
         ! video/x-raw,format=NV12,width=320,height=240,framerate=30/1 \
         ! nvh264enc preset="$p" \
         ! fakesink sync=false \
         >/dev/null 2>&1
    then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

# Pick an H.265/HEVC encoder fragment for `! video/x-raw,format=NV12 !`.
# Mirrors pick_h264_pipeline — same driver-550+ legacy-preset deprecation
# hits nvh265enc, same modern-CUDA API name surface (`rate-control` not
# `rc-mode`), same probe-then-cache pattern. Software x265enc is *not* in
# the fallback chain: the slowdown ffmpeg pass would have to use libx265
# too to keep segments codec-uniform for `-c copy` concat, and libx265
# at 1080p60 is 3-5× slower than libx264 — would blow render budgets.
# So if no NVENC HEVC encoder is available, we return nonzero and the
# caller falls back to h264 end-to-end.
# Result cached per-process in GS_NVENC_PICK_H265; override family with
# GS_NVENC_H265_ELEMENT.
#
# kbps is the h264-equivalent target bitrate. HEVC at the same bitrate
# looks markedly better than h264, so we scale to 70% inside the picker
# — callers pass one number and don't need to know about codec
# efficiency. Comparable visual quality, ~30% smaller files.
#
# Usage: pick_h265_pipeline <gop> <kbps-h264-equiv> [live|clip]
pick_h265_pipeline() {
  local gop="${1:?gop required}"
  local kbps="${2:?kbps required}"
  local mode="${3:-live}"

  if [ -z "${GS_NVENC_PICK_H265:-}" ]; then
    GS_NVENC_PICK_H265=$(_resolve_h265_method) || true
    export GS_NVENC_PICK_H265
  fi

  local h265_kbps=$((kbps * 7 / 10))

  case "${GS_NVENC_PICK_H265:-none}" in
    nvcudah265enc)
      local preset tune
      case "$mode" in
        clip) preset="p5"; tune="high-quality" ;;
        *)    preset="p4"; tune="low-latency"  ;;
      esac
      printf 'cudaupload ! nvcudah265enc preset=%s tune=%s rate-control=cbr gop-size=%s bitrate=%s' \
        "$preset" "$tune" "$gop" "$h265_kbps"
      ;;
    nvh265enc:*)
      local preset="${GS_NVENC_PICK_H265#nvh265enc:}"
      printf 'nvh265enc preset=%s rc-mode=cbr gop-size=%s bitrate=%s' \
        "$preset" "$gop" "$h265_kbps"
      ;;
    *)
      return 1
      ;;
  esac
}

# Returns 0 if a hardware h265 encoder pipeline can be resolved on this
# pod, 1 otherwise. Cheap to call — caches state in GS_NVENC_PICK_H265
# so a later pick_h265_pipeline doesn't re-probe.
h265_available() {
  if [ -z "${GS_NVENC_PICK_H265:-}" ]; then
    GS_NVENC_PICK_H265=$(_resolve_h265_method) || true
    export GS_NVENC_PICK_H265
  fi
  case "${GS_NVENC_PICK_H265:-none}" in
    none|"") return 1 ;;
    *)       return 0 ;;
  esac
}

_resolve_h265_method() {
  # Same stdout-capture contract as _resolve_h264_method: log lines must
  # go to stderr or they get glued into GS_NVENC_PICK_H265 and break the
  # pipeline parse.
  local force="${GS_NVENC_H265_ELEMENT:-auto}"

  if [ "$force" = "auto" ] || [ "$force" = "nvcudah265enc" ]; then
    if gst-inspect-1.0 nvcudah265enc >/dev/null 2>&1 \
       && gst-inspect-1.0 cudaupload >/dev/null 2>&1 \
       && _probe_nvcudah265enc; then
      log "  encoder: nvcudah265enc (GPU, modern API)" >&2
      printf 'nvcudah265enc'
      return 0
    fi
    [ "$force" = "nvcudah265enc" ] && \
      warn "GS_NVENC_H265_ELEMENT=nvcudah265enc forced but unavailable — falling through"
  fi

  if [ "$force" = "auto" ] || [ "$force" = "nvh265enc" ]; then
    if gst-inspect-1.0 nvh265enc >/dev/null 2>&1; then
      local preset
      if preset=$(_probe_nvh265enc_preset); then
        log "  encoder: nvh265enc preset=$preset (GPU, legacy API)" >&2
        printf 'nvh265enc:%s' "$preset"
        return 0
      fi
    fi
    [ "$force" = "nvh265enc" ] && \
      warn "GS_NVENC_H265_ELEMENT=nvh265enc forced but unavailable — falling through"
  fi

  log "  encoder: no NVENC HEVC encoder available — caller will fall back to h264" >&2
  printf 'none'
  return 1
}

_probe_nvcudah265enc() {
  gst-launch-1.0 -q \
    videotestsrc num-buffers=1 \
    ! video/x-raw,format=NV12,width=320,height=240,framerate=30/1 \
    ! cudaupload \
    ! nvcudah265enc preset=p4 tune=low-latency rate-control=cbr gop-size=60 bitrate=2000 \
    ! fakesink sync=false \
    >/dev/null 2>&1
}

_probe_nvh265enc_preset() {
  local p
  for p in ${NVH265_PRESET_CANDIDATES:-low-latency-hq low-latency hq default}; do
    if gst-launch-1.0 -q \
         videotestsrc num-buffers=1 \
         ! video/x-raw,format=NV12,width=320,height=240,framerate=30/1 \
         ! nvh265enc preset="$p" \
         ! fakesink sync=false \
         >/dev/null 2>&1
    then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
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
