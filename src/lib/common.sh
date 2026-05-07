# shellcheck shell=bash
# Shared helpers. Source from anywhere under src/.

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
# mediamtx HTTP control API — start_capture polls to verify a publish
# actually landed (gst-launch loops happily on a failing srt sink).
: "${MEDIAMTX_API_BASE:=http://mediamtx.5stack.svc.cluster.local:9997}"
: "${GAME_STREAM_DOMAIN:=hls.5stack.gg}"
# LOG_DIR is a misnomer — k8s captures stdout/stderr; this holds
# non-log state (status files, JSON caches, marker files, pid files).
: "${LOG_DIR:=/tmp/game-streamer}"
# Xorg's setuid wrapper accepts only a BARE filename for -config (not
# an absolute path); the Dockerfile drops the file into /etc/X11/.
: "${XORG_CONFIG:=xorg-dummy.conf}"
: "${CS2_GRAPHICS_PRESET:=low}"
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
  if declare -F report_status >/dev/null 2>&1; then
    report_status status=errored "error=$*" >/dev/null 2>&1 || true
  fi
  if declare -F broadcast_batch_error >/dev/null 2>&1; then
    broadcast_batch_error status=errored "error=$*" >/dev/null 2>&1 || true
  fi
  # Brief flush so the daemon's poll cycle PUTs before the Job is reaped.
  # batch_error is synchronous curl + wait, so it needs no flush; the
  # sleep is purely for the daemon path.
  if declare -F report_status >/dev/null 2>&1; then
    sleep "${STATUS_DIE_FLUSH_SECONDS:-3}" 2>/dev/null || true
  fi
  exit 1
}

# Stdout+stderr of the daemon stream to this process's stderr with a
# "[<tag>] " prefix per line — k8s container logs become self-describing.
# nohup detaches so HUP doesn't kill it when launcher scripts exit;
# the awk subprocess reparents to PID 1 and keeps tagging.
spawn_logged() {
  local tag="$1"; shift
  nohup "$@" \
    > >(awk -v t="$tag" '{print "["t"] " $0; fflush()}' >&2) \
    2>&1 &
  SPAWNED_PID=$!
}

# Pick an H.264 encoder fragment. Tries nvcudah264enc, then nvh264enc
# with a probed preset (driver 550+ dropped legacy preset GUIDs so
# strict validation rejects them), then x264enc. Cached per-process in
# GS_NVENC_PICK; override with GS_NVENC_ELEMENT.
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
      # The modern CUDA encoder uses `rate-control` (not `rc-mode` like
      # the legacy nvh264enc) — wrong name dies at pipeline-parse.
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
  # Called via $(...) so stdout is captured into GS_NVENC_PICK. Any
  # informational logging MUST go to stderr — otherwise it gets glued
  # onto the encoder name and the gst-launch pipeline collapses to
  # "... ! ! ..." (syntax error).
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
      warn "GS_NVENC_ELEMENT=nvcudah264enc forced but unavailable"
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
      warn "GS_NVENC_ELEMENT=nvh264enc forced but unavailable"
  fi

  log "  encoder: x264enc (software fallback)" >&2
  printf 'x264enc'
}

# Probe with the SAME property surface used in production — a future
# GStreamer rev that renames/drops a property fails here instead of
# silently passing and crashing at real-pipeline parse mid-match.
_probe_nvcudah264enc() {
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

load_env() {
  local f="$SRC_DIR/.env"
  if [ -f "$f" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
  fi
}
