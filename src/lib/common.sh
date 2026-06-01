# shellcheck shell=bash
# Shared helpers. Source from anywhere under src/.

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SRC_DIR/lib"
FLOWS_DIR="$SRC_DIR/flows"
export SRC_DIR LIB_DIR FLOWS_DIR

: "${LOG_DIR:=/tmp/game-streamer}"
# start_xorg may have to fall back off :0 when the host already runs a
# desktop there. It records the resolved display in $LOG_DIR/display so
# fresh flows inherit the right value. The file wins over inherited env
# because game-streamer.sh sources common.sh first (exporting DISPLAY=:0)
# and then forks setup-steam / execs run-demo with that stale :0 still
# in their env — the file is the only source of truth across the
# fork/exec boundary.
if [ -r "$LOG_DIR/display" ]; then
  DISPLAY=$(cat "$LOG_DIR/display" 2>/dev/null)
fi
: "${DISPLAY:=:0}"
: "${XDG_RUNTIME_DIR:=/tmp/xdg-runtime-root}"
: "${STEAM_HOME:=/root/.local/share/Steam}"
: "${STEAM_LIBRARY:=/mnt/game-streamer}"
: "${CS2_DIR:=$STEAM_LIBRARY/steamapps/common/Counter-Strike Global Offensive}"
# Persistent NVIDIA GLCache dir (holds cs2's compiled Vulkan shaders). The
# __GL_SHADER_DISK_CACHE* env that enables it is exported per-cs2 only (see
# shader-cache.sh) — pod-wide regressed Steam bring-up.
: "${GL_SHADER_CACHE_DIR:=$STEAM_LIBRARY/nvcache}"
# Steam runs fossilize_replay rate-limited (background "don't hog the box"
# mode). This pod is dedicated, so let it run full-tilt. Only fossilize
# reads this, so it's safe to export globally.
: "${FOSSILIZE_DISABLE_RATE_LIMITER:=1}"
: "${MEDIAMTX_SRT_BASE:=srt://mediamtx.5stack.svc.cluster.local:8890}"
# mediamtx HTTP control API — start_capture polls to verify a publish
# actually landed (gst-launch loops happily on a failing srt sink).
: "${MEDIAMTX_API_BASE:=http://mediamtx.5stack.svc.cluster.local:9997}"
: "${GAME_STREAM_DOMAIN:=hls.5stack.gg}"
# LOG_DIR (defaulted above) is a misnomer — k8s captures stdout/stderr;
# this holds non-log state (status files, JSON caches, marker files,
# pid files, and the resolved-display pointer for cross-flow state).
# Xorg's setuid wrapper accepts only a BARE filename for -config (not
# an absolute path); the Dockerfile drops the file into /etc/X11/.
: "${CS2_DISPLAY_RES:=1920x1080}"
CS2_WIDTH="${CS2_DISPLAY_RES%x*}"
CS2_HEIGHT="${CS2_DISPLAY_RES#*x}"
# Pick the matching Xorg dummy config. Unknown resolutions fall back
# to 1080p — only the configs we ship work, anything else would die
# at Xorg startup. The available set is intentionally narrow: 1080p
# and 1440p match the UI's resolution selector.
case "$CS2_DISPLAY_RES" in
  2560x1440) : "${XORG_CONFIG:=xorg-dummy-1440p.conf}" ;;
  *)         : "${XORG_CONFIG:=xorg-dummy-1080p.conf}" ;;
esac
: "${CS2_VIDEO_SETTINGS:={}}"
mkdir -p "$LOG_DIR" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
# Driver won't create the GLCache dir itself.
mkdir -p "$GL_SHADER_CACHE_DIR" 2>/dev/null || true

export DISPLAY XDG_RUNTIME_DIR STEAM_HOME STEAM_LIBRARY CS2_DIR \
       MEDIAMTX_SRT_BASE MEDIAMTX_API_BASE GAME_STREAM_DOMAIN \
       LOG_DIR XORG_CONFIG CS2_VIDEO_SETTINGS \
       CS2_DISPLAY_RES CS2_WIDTH CS2_HEIGHT \
       GL_SHADER_CACHE_DIR FOSSILIZE_DISABLE_RATE_LIMITER

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
      # No leading `cudaupload` — pick_scale_convert owns the system->CUDA
      # upload (and does the scale/convert on the GPU when possible).
      printf 'nvcudah264enc preset=%s tune=%s rate-control=cbr gop-size=%s bitrate=%s' \
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

# Pick an H.265/HEVC encoder fragment. Returns nonzero if no NVENC HEVC
# encoder is available; caller must fall back to h264 (no software fallback —
# libx265 is too slow for the live and clip ffmpeg passes).
# kbps is the h264-equivalent target; scaled to 70% internally for HEVC.
# Cached in GS_NVENC_PICK_H265; override with GS_NVENC_H265_ELEMENT.
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
      # No leading `cudaupload` — pick_scale_convert owns the system->CUDA
      # upload (and does the scale/convert on the GPU when possible).
      printf 'nvcudah265enc preset=%s tune=%s rate-control=cbr gop-size=%s bitrate=%s' \
        "$preset" "$tune" "$gop" "$h265_kbps"
      ;;
    nvh265enc:*)
      local preset="${GS_NVENC_PICK_H265#nvh265enc:}"
      printf 'nvh265enc preset=%s rc-mode=cbr gop-size=%s bitrate=%s' \
        "$preset" "$gop" "$h265_kbps"
      ;;
    none|"")
      return 1
      ;;
    *)
      warn "GS_NVENC_PICK_H265='${GS_NVENC_PICK_H265}' unrecognized — treating as no NVENC HEVC"
      return 1
      ;;
  esac
}

# 0 if NVENC HEVC is available on this pod. Caches into GS_NVENC_PICK_H265.
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
  # Log to stderr only — stdout is captured into GS_NVENC_PICK_H265.
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

# Populate the NVENC pick cache for $codec in THIS shell if it's cold.
# pick_h26{4,5}_pipeline is invoked as `enc=$(pick_… )`, so the export it does
# happens in a SUBSHELL and never reaches the parent — and pick_scale_convert
# then runs in its own subshell with a cold cache. Re-resolve here (the same
# deterministic gst probe, stderr muted so the "encoder:" line isn't logged a
# second time) so the scaler's CUDA-vs-CPU choice matches the encoder actually
# selected. Without this the scaler picked CPU for a CUDA encoder → the
# "CUDA encoder fed non-CUDA memory" warning + needless CPU scaling.
_ensure_nvenc_pick() {
  case "${1:-h264}" in
    h265|hevc)
      [ -n "${GS_NVENC_PICK_H265:-}" ] && return 0
      GS_NVENC_PICK_H265=$(_resolve_h265_method 2>/dev/null) || true
      export GS_NVENC_PICK_H265 ;;
    *)
      [ -n "${GS_NVENC_PICK:-}" ] && return 0
      GS_NVENC_PICK=$(_resolve_h264_method 2>/dev/null) || true
      export GS_NVENC_PICK ;;
  esac
}

# True when the resolved NVENC element for $codec is the modern CUDA
# encoder (nvcuda*), which consumes CUDA memory and so must be fed an upload.
# Self-heals a cold cache via _ensure_nvenc_pick so it's correct even when
# called from a different subshell than the one that picked the encoder.
_active_encoder_is_cuda() {
  _ensure_nvenc_pick "${1:-h264}"
  case "${1:-h264}" in
    h265|hevc) [ "${GS_NVENC_PICK_H265:-}" = "nvcudah265enc" ] ;;
    *)         [ "${GS_NVENC_PICK:-}" = "nvcudah264enc" ] ;;
  esac
}

# True when GPU scale+convert is usable: not disabled via GS_GPU_SCALE, and
# both cudaupload + cudaconvertscale exist on this pod. Cached per-process.
_cuda_scale_available() {
  case "${GS_GPU_SCALE:-auto}" in
    0|off|false|no) return 1 ;;
  esac
  if [ -z "${GS_CUDASCALE_OK:-}" ]; then
    if gst-inspect-1.0 cudaupload >/dev/null 2>&1 \
       && gst-inspect-1.0 cudaconvertscale >/dev/null 2>&1; then
      GS_CUDASCALE_OK=1
    else
      GS_CUDASCALE_OK=0
    fi
    export GS_CUDASCALE_OK
  fi
  [ "$GS_CUDASCALE_OK" = 1 ]
}

# Emit the scale + colorspace-convert fragment that feeds the encoder.
# When the active encoder is a CUDA NVENC element and cudaconvertscale is
# present, the scale (e.g. 1440p->1080p) and RGBx->NV12 convert run on the
# GPU (cudaupload ! cudaconvertscale), removing the CPU videoscale +
# videoconvert that otherwise competes with cs2 for cores. The CUDA encoder
# fragments deliberately drop their own cudaupload — this fragment owns it.
# Falls back to the all-CPU path for legacy nvenc / x264, and to a
# CPU-convert-then-upload path if a CUDA encoder is paired with a pod that
# lacks cudaconvertscale (so the encoder still receives CUDA memory).
# Usage: pick_scale_convert <out_w> <out_h> <fps> <codec>
pick_scale_convert() {
  local w="${1:?width required}" h="${2:?height required}"
  local fps="${3:?fps required}" codec="${4:-h264}"
  local cpu="videoscale ! video/x-raw,width=${w},height=${h},framerate=${fps}/1 ! videoconvert ! video/x-raw,format=NV12"
  if _active_encoder_is_cuda "$codec"; then
    if _cuda_scale_available; then
      log "  scaler: cudaconvertscale (GPU scale+convert)" >&2
      printf 'cudaupload ! cudaconvertscale ! video/x-raw(memory:CUDAMemory),format=NV12,width=%s,height=%s,framerate=%s/1' \
        "$w" "$h" "$fps"
      return 0
    fi
    # CUDA encoder but no GPU scaler: convert on CPU, then upload so the
    # encoder still gets the CUDA memory it requires.
    log "  scaler: CPU videoscale+videoconvert then cudaupload (cudaconvertscale unavailable)" >&2
    printf '%s ! cudaupload' "$cpu"
    return 0
  fi
  log "  scaler: CPU videoscale+videoconvert" >&2
  printf '%s' "$cpu"
}

# Contract guard for the pick_scale_convert -> encoder pairing: a CUDA NVENC
# element (nvcudah26{4,5}enc) consumes CUDA memory, which pick_scale_convert
# supplies (cudaupload / cudaconvertscale). Warns loudly if a caller paired a CUDA
# encoder with a convert fragment that doesn't produce CUDA memory — i.e. built a
# pipeline without pick_scale_convert in front of the encoder. Usage:
# _assert_cuda_chain "<convert fragment>" "<encoder fragment>".
_assert_cuda_chain() {
  case "$2" in
    *nvcudah264enc*|*nvcudah265enc*)
      case "$1" in
        *cudaupload*|*CUDAMemory*) ;;
        *) warn "BUG: CUDA encoder fed non-CUDA memory — pick_scale_convert must precede the encoder (convert='$1')" ;;
      esac ;;
  esac
}

# obs-vkcapture present-hook needs nvidia-drm modeset on (its dmabuf sharing).
# True unless we have POSITIVE evidence it's off — the host kernel param is visible
# via the shared /sys; unreadable/absent -> assume on (don't block the default path
# on a missing sysfs).
_drm_modeset_on() {
  local f=/sys/module/nvidia_drm/parameters/modeset v
  [ -r "$f" ] || return 0
  v=$(cat "$f" 2>/dev/null)
  [ "$v" != "N" ] && [ "$v" != "0" ]
}

# True when CLIP_CAPTURE_METHOD selects vkcapture AND it can run here (consumer
# binary built + modeset on). Drives the present-hook for clips, and for the
# live/demo composite (cs2 via present-hook + HUD overlay) in stream.sh. A miss =>
# the ximagesrc fallback, which needs no DRM. NOTE: does not check cs2-running —
# callers that capture pre-cs2 (DEBUG_STREAM boot) gate on that separately.
vkcapture_available() {
  [ "${CLIP_CAPTURE_METHOD:-vkcapture}" = "vkcapture" ] || return 1
  command -v vkcapture-consumer >/dev/null 2>&1 || return 1
  _drm_modeset_on
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
