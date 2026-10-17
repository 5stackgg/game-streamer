# shellcheck shell=bash
# Shared helpers. Source from anywhere under src/.

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SRC_DIR/lib"
FLOWS_DIR="$SRC_DIR/flows"
export SRC_DIR LIB_DIR FLOWS_DIR

# _gs_pci_check ADDR: 0 when ADDR names a PCI function that an AMD GPU job can use: the
# lowercase sysfs name with the domain (0000:c6:00.0), a sysfs entry, vendor 0x1002 and a
# drm/renderD* entry. Sets _GS_PCI_ID to <vendor>:<device> in lowercase hex without 0x and
# _GS_PCI_RENDER to the renderD name. Otherwise it sets _GS_PCI_FAIL to the failed check
# and returns 1. Silent: preflight_vulkan reports the failure. The hex letters are spelled
# out so that no locale lets an uppercase name through.
_gs_pci_check() {
  local dir="${GS_SYSFS_ROOT:-/sys}/bus/pci/devices/$1" v="" d="" r
  _GS_PCI_ID="" _GS_PCI_RENDER="" _GS_PCI_FAIL=""
  if ! [[ "$1" =~ ^[0-9abcdef]{4}:[0-9abcdef]{2}:[0-9abcdef]{2}[.][0-7]$ ]]; then
    _GS_PCI_FAIL="format (lowercase dddd:bb:dd.f with the domain)"
    return 1
  fi
  if [ ! -d "$dir" ]; then
    _GS_PCI_FAIL="sysfs entry ($dir)"
    return 1
  fi
  { read -r v < "$dir/vendor" || :; } 2>/dev/null
  { read -r d < "$dir/device" || :; } 2>/dev/null
  if [ "$v" != 0x1002 ]; then
    _GS_PCI_FAIL="vendor 0x1002 (sysfs vendor ${v:-unreadable})"
    return 1
  fi
  for r in "$dir"/drm/renderD*; do
    if [ -e "$r" ]; then _GS_PCI_RENDER="${r##*/}"; break; fi
  done
  if [ -z "$_GS_PCI_RENDER" ]; then
    _GS_PCI_FAIL="render node (no $dir/drm/renderD*)"
    return 1
  fi
  _GS_PCI_ID="${v#0x}:${d#0x}"
}

# gs_gpu_env: picks this pod's AMD GPU and exports the Vulkan selection for it. Inputs:
# GS_GPU_VENDOR, GS_GPU_PCI_ADDRESS and the optional GS_RENDER_NODE hint. 'amd' plus a
# valid address selects that device (source env); 'amd' with an address that fails
# _gs_pci_check selects nothing, and preflight_vulkan dies. An address with no vendor takes
# the vendor from sysfs (source pci). With neither set, a node with no NVIDIA driver and
# exactly one AMD display device with a render node selects it (source self; docker run
# and dev only). NVIDIA, and any value other than amd, export nothing. Pod env wins for
# every export except GS_RENDER_NODE, which is always derived here because render node
# numbers change across boots. The source and the hint are exported by the first shell
# only, so the flows it starts keep its answer. GS_SYSFS_ROOT and GS_PROC_ROOT are test
# prefixes. Silent: say, log and warn are defined further down.
gs_gpu_env() {
  local vendor="${GS_GPU_VENDOR:-}" addr="${GS_GPU_PCI_ADDRESS:-}" src="" mode=""
  local devs="${GS_SYSFS_ROOT:-/sys}/bus/pci/devices" dir class v r found="" n=0
  if [ "$vendor" = amd ]; then
    src="env"
  elif [ -n "$vendor" ]; then
    return 0
  elif [ -n "$addr" ]; then
    v=""
    { read -r v < "$devs/$addr/vendor" || :; } 2>/dev/null
    [ "$v" = 0x1002 ] || return 0
    src="pci"
  else
    [ -e "${GS_PROC_ROOT:-/proc}/driver/nvidia" ] && return 0
    for dir in "$devs"/*; do
      class="" v=""
      { read -r class < "$dir/class" || :; } 2>/dev/null
      case "$class" in 0x03????) ;; *) continue ;; esac
      { read -r v < "$dir/vendor" || :; } 2>/dev/null
      case "$v" in
        0x10de) return 0 ;;
        0x1002)
          for r in "$dir"/drm/renderD*; do
            if [ -e "$r" ]; then n=$((n + 1)); found="${dir##*/}"; break; fi
          done
          ;;
      esac
    done
    [ "$n" -eq 1 ] || return 0
    addr="$found"
    src="self"
    export GS_GPU_PCI_ADDRESS="$addr"
  fi
  export GS_GPU_VENDOR=amd
  if [ -z "${GS_GPU_VENDOR_SOURCE+x}" ]; then
    export GS_GPU_VENDOR_SOURCE="$src"
    if [ -n "${GS_RENDER_NODE:-}" ]; then export GS_RENDER_NODE_HINT="$GS_RENDER_NODE"; fi
  fi
  : "${VK_LOADER_DRIVERS_SELECT:=*radeon*}"
  export VK_LOADER_DRIVERS_SELECT
  if _gs_pci_check "$addr"; then
    : "${MESA_VK_DEVICE_SELECT:=$_GS_PCI_ID!}"
    export MESA_VK_DEVICE_SELECT
    export GS_RENDER_NODE="/dev/dri/$_GS_PCI_RENDER"
  else
    unset GS_RENDER_NODE
  fi
  { read -r mode < "$LOG_DIR/wsi_mode" || :; } 2>/dev/null
  if [ "$mode" = sw ]; then
    : "${MESA_VK_WSI_DEBUG:=sw}"
    export MESA_VK_WSI_DEBUG
  fi
  return 0
}

: "${LOG_DIR:=/tmp/game-streamer}"
# start_xorg may have to fall back off :0 when the host already runs a
# desktop there. It records the resolved display in $LOG_DIR/display so
# fresh flows inherit the right value. The file wins over inherited env
# because game-streamer.sh sources common.sh first (exporting DISPLAY=:0)
# and then forks setup-steam / execs run-demo with that stale :0 still
# in their env — the file is the only source of truth across the
# fork/exec boundary.
# On AMD, until start_xorg writes that file, the block after the gs_gpu_env call below
# moves the first display to :20 (or GS_X_DISPLAY_BASE) instead.
if [ -r "$LOG_DIR/display" ]; then
  DISPLAY=$(cat "$LOG_DIR/display" 2>/dev/null)
fi
# Pick the GPU first: the defaults below that depend on the vendor read its exports.
gs_gpu_env
# AMD only: X starts at base display :20, or at GS_X_DISPLAY_BASE when that is a whole
# number, and start_xorg then scans and claims :<base> to :<base+9>. The pods run on the
# host network and see the host's X sockets, so :20 keeps clear of a host desktop (:0 and
# :1) and of xrdp (:10 and up). The assignment is explicit because the image sets
# ENV DISPLAY=:0: on AMD a DISPLAY from the pod env is ignored until start_xorg writes
# $LOG_DIR/display.
if [ ! -r "$LOG_DIR/display" ] && [ "${GS_GPU_VENDOR:-}" = amd ]; then
  _b="${GS_X_DISPLAY_BASE:-20}"
  case "$_b" in ''|*[!0-9]*) _b=20 ;; esac
  DISPLAY=":$_b"
  unset _b
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
# mediamtx HTTP control API — start_capture times connects to it to size the
# SRT latency (see srt_latency_for_rtt in stream.sh).
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
# On AMD the dummy X server runs next to the host's own display server, so the default is
# the coexist config. An explicit XORG_CONFIG still wins, then GS_DUMMY_CONFIG. The case
# below then finds XORG_CONFIG set and keeps it; NVIDIA and unset run it unchanged.
if [ "${GS_GPU_VENDOR:-}" = amd ]; then
  case "$CS2_DISPLAY_RES" in
    2560x1440) : "${XORG_CONFIG:=${GS_DUMMY_CONFIG:-xorg-coexist-1440p.conf}}" ;;
    *)         : "${XORG_CONFIG:=${GS_DUMMY_CONFIG:-xorg-coexist-1080p.conf}}" ;;
  esac
fi
# Pick the matching Xorg dummy config. Unknown resolutions fall back
# to 1080p — only the configs we ship work, anything else would die
# at Xorg startup. The available set is intentionally narrow: 1080p
# and 1440p match the UI's resolution selector.
case "$CS2_DISPLAY_RES" in
  2560x1440) : "${XORG_CONFIG:=xorg-dummy-1440p.conf}" ;;
  *)         : "${XORG_CONFIG:=xorg-dummy-1080p.conf}" ;;
esac
# Escaped closing brace: `${VAR:={}}` mis-parses to a bare `{` (invalid
# JSON); escaping yields the literal `{}` default.
: "${CS2_VIDEO_SETTINGS:={\}}"
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

# gs_display_tier: prints this pod's display tier, A or C: the first word of
# $LOG_DIR/display_tier, which start_xorg writes once per pod on AMD. It prints nothing
# unless GS_GPU_VENDOR is amd and the file exists, and always returns 0. It uses bash
# builtins only (read -r), so it forks nothing.
gs_display_tier() {
  local tier=""
  [ "${GS_GPU_VENDOR:-}" = amd ] || return 0
  [ -e "$LOG_DIR/display_tier" ] || return 0
  { read -r tier _ < "$LOG_DIR/display_tier" || :; } 2>/dev/null
  if [ -n "$tier" ]; then printf '%s\n' "$tier"; fi
  return 0
}

# _gs_num FILE DIVISOR: sets _GS_NUM to the number on the first line of FILE divided by
# DIVISOR, rounded down, or to '?' when FILE is missing or unreadable or that line is not
# 1 to 18 digits.
_gs_num() {
  local v=""
  _GS_NUM="?"
  { read -r v < "$1" || :; } 2>/dev/null
  if [[ "$v" =~ ^[0-9]{1,18}$ ]]; then _GS_NUM=$((10#$v / $2)); fi
  return 0
}

# _gs_hwmon DIR NAME: sets _GS_HWMON to DIR/hwmon/hwmon<n>/NAME for the lowest <n> whose
# directory has NAME, or to "" when none has it. The numbers are compared as numbers, so
# hwmon2 comes before hwmon10.
_gs_hwmon() {
  local h n low=""
  _GS_HWMON=""
  for h in "$1"/hwmon/hwmon*; do
    n="${h##*/hwmon}"
    [[ "$n" =~ ^[0-9]{1,9}$ ]] || continue
    [ -e "$h/$2" ] || continue
    if [ -z "$low" ] || [ "$((10#$n))" -lt "$((10#$low))" ]; then
      low="$n"
      _GS_HWMON="$h/$2"
    fi
  done
  return 0
}

# gs_gpu_sample: one line of AMD GPU telemetry for the DIAG lines, read under
# ${GS_SYSFS_ROOT:-/sys}/bus/pci/devices/$GS_GPU_PCI_ADDRESS:
#   util=<pct> vramMiB=<n> clkMHz=<n> tempC=<n> vcn=<pct>
# util is gpu_busy_percent, vramMiB is mem_info_vram_used in MiB, clkMHz is freq1_input
# (Hz) in MHz and tempC is temp1_input (millidegrees) in degrees, both from the
# lowest-numbered hwmon/hwmon* directory that has the file, and vcn is vcn_busy_percent.
# Conversions round down. A field it cannot read, or whose file holds anything but digits,
# prints as '?', and so does every field when the address is empty or malformed. Bash
# builtins only: it writes nothing and always returns 0. AMD only: NVIDIA keeps nvidia-smi.
# GS_SYSFS_ROOT is a test prefix.
gs_gpu_sample() {
  local addr="${GS_GPU_PCI_ADDRESS:-}" dir util="?" vram="?" clk="?" temp="?" vcn="?"
  if [[ "$addr" =~ ^[0-9abcdef]{4}:[0-9abcdef]{2}:[0-9abcdef]{2}[.][0-7]$ ]]; then
    dir="${GS_SYSFS_ROOT:-/sys}/bus/pci/devices/$addr"
    _gs_num "$dir/gpu_busy_percent" 1
    util="$_GS_NUM"
    _gs_num "$dir/mem_info_vram_used" 1048576
    vram="$_GS_NUM"
    _gs_hwmon "$dir" freq1_input
    if [ -n "$_GS_HWMON" ]; then _gs_num "$_GS_HWMON" 1000000; clk="$_GS_NUM"; fi
    _gs_hwmon "$dir" temp1_input
    if [ -n "$_GS_HWMON" ]; then _gs_num "$_GS_HWMON" 1000; temp="$_GS_NUM"; fi
    _gs_num "$dir/vcn_busy_percent" 1
    vcn="$_GS_NUM"
  fi
  printf 'util=%s vramMiB=%s clkMHz=%s tempC=%s vcn=%s\n' "$util" "$vram" "$clk" "$temp" "$vcn"
  return 0
}

# gs_sw_fps_clamp VALUE: prints the cs2 frame cap to launch with. When $LOG_DIR/wsi_mode
# holds sw (tier A on AMD, where every present is a CPU copy into X), a VALUE that is 0,
# empty or above GS_SW_WSI_FPS_MAX (default 120) prints GS_SW_WSI_FPS_MAX. Otherwise, and
# always without sw, it prints VALUE unchanged, so it changes nothing on tier C (hw) or on
# NVIDIA (no wsi_mode file). A GS_SW_WSI_FPS_MAX that is not a whole number from 1 to
# 999999999 counts as unset, and a VALUE that is not a number comes back unchanged. It
# prints nothing else and returns 0.
gs_sw_fps_clamp() {
  local v="${1:-}" mode="" max="${GS_SW_WSI_FPS_MAX:-}" n
  { read -r mode < "$LOG_DIR/wsi_mode" || :; } 2>/dev/null
  if [ "$mode" = sw ]; then
    [[ "$max" =~ ^[1-9][0-9]{0,8}$ ]] || max=120
    if [ -z "$v" ]; then
      v="$max"
    elif [[ "$v" =~ ^[0-9]+$ ]]; then
      n="${v#"${v%%[!0]*}"}"
      if [ -z "$n" ] || [ "${#n}" -gt 9 ] || [ "$n" -gt "$max" ]; then v="$max"; fi
    fi
  fi
  printf '%s\n' "$v"
  return 0
}

# The spec-server refuses any call without this pod's SPEC_SERVER_TOKEN, so
# every in-pod call to it goes through here rather than a bare curl.
spec_curl() {
  curl --header "Authorization: Bearer ${SPEC_SERVER_TOKEN:-}" "$@"
}

# Detect cs2's GetClassBaseline replay crash (issue #3429): cs2 halts the demo
# but stays alive, so a render would capture frozen frames. The sentinel tells
# the batch to relaunch cs2 before the next job.
CS2_FATAL_SENTINEL="${CLIP_OUT_DIR:-/tmp/game-streamer/clips}/.cs2-fatal"
# A render exits with this after a fatal when the batch will relaunch cs2 and retry it.
# shellcheck disable=SC2034
CS2_FATAL_RETRY_RC=75

# Echo the GetClassBaseline line if cs2 logged one since byte offset $1 (caller
# snapshots before playback so a stale line can't fail an unrelated job).
# Case-insensitive: Valve logs both "...failed" and "find(35) Failed for class ...".
cs2_fatal_reason() {
  local log="${CS2_DIR}/game/csgo/console.log" since="${1:-0}" hit
  if [ -f "$log" ]; then
    hit=$(tail -c "+$((since + 1))" "$log" 2>/dev/null \
      | grep -aioE 'GetClassBaseline[^[:cntrl:]]*failed' | tail -1) || true
    [ -n "$hit" ] && { printf '%s' "$hit"; return 0; }
  fi
  # console.log buffers; the Error dialog is a real-time X window.
  if command -v xdotool >/dev/null 2>&1 \
     && [ -n "$(timeout 3 xdotool search --name '^Error$' 2>/dev/null | head -1)" ]; then
    printf 'cs2 fatal Error dialog'
    return 0
  fi
  return 1
}

cs2_mark_fatal() {
  mkdir -p "$(dirname "$CS2_FATAL_SENTINEL")" 2>/dev/null || true
  printf '%s\n' "${1:-cs2 GetClassBaseline fatal}" > "$CS2_FATAL_SENTINEL" 2>/dev/null || true
}

# mawk (Ubuntu's awk) block-buffers its input from a pipe, so a daemon's lines only
# surfaced in bursts (often all at exit, every line carrying the same timestamp).
# -W interactive makes it read line by line; gawk doesn't need or know it.
if awk -W version 2>&1 | grep -q mawk; then GS_AWK_LINES=(-W interactive); else GS_AWK_LINES=(); fi

# Stdout+stderr of the daemon stream to this process's stderr with a
# "[<tag>] " prefix per line — k8s container logs become self-describing.
# nohup detaches so HUP doesn't kill it when launcher scripts exit;
# the awk subprocess reparents to PID 1 and keeps tagging.
spawn_logged() {
  local tag="$1"; shift
  nohup "$@" \
    > >(awk "${GS_AWK_LINES[@]}" -v t="$tag" '{print "["t"] " $0; fflush()}' >&2) \
    2>&1 &
  SPAWNED_PID=$!
}

# GStreamer element probes are slow — each gst-inspect / test pipeline loads the
# nvcodec plugin and initialises CUDA (~1-2s) — and most callers run inside $(...)
# subshells, where an exported "per-process" cache dies with the subshell: clip
# capture re-probed the encoder and scaler on every segment (~15s). The answers
# can't change for the life of the pod, so they're cached in a file.
GS_PROBE_CACHE="${GS_PROBE_CACHE:-/tmp/game-streamer/gst-probes.env}"

# Load <var> from the probe cache unless it's already set. 0 if it's set now.
_probe_cache_load() {
  local var="$1" line
  [ -n "${!var:-}" ] && return 0
  line=$(grep -m1 "^${var}=" "$GS_PROBE_CACHE" 2>/dev/null) || return 1
  printf -v "$var" '%s' "${line#*=}"
  export "${var?}"
  [ -n "${!var}" ]
}

# Append <var>'s value to the probe cache (the first entry wins on load).
_probe_cache_store() {
  local var="$1"
  [ -n "${!var:-}" ] || return 0
  mkdir -p "$(dirname "$GS_PROBE_CACHE")" 2>/dev/null || return 0
  printf '%s=%s\n' "$var" "${!var}" >> "$GS_PROBE_CACHE" 2>/dev/null || true
}

# Adaptive-quantization props for a CUDA NVENC element, when it has them: spatial AQ
# moves bits into flat/dark areas and fast detail (smoke, flashes, sky) that plain CBR
# leaves blocky; clips also get temporal AQ. Probed with gst-inspect once per pod (a
# property the element lacks would kill the pipeline at parse time).
# Usage: _nvenc_aq_props <element> <live|clip>
_nvenc_aq_props() {
  local el="$1" mode="$2" var="GS_AQ_${1//[!A-Za-z0-9]/_}" props=""
  if ! _probe_cache_load "$var"; then
    local spec
    spec=$(gst-inspect-1.0 "$el" 2>/dev/null)
    local found=""
    grep -q '^ *spatial-aq ' <<<"$spec" && found+="s"
    grep -q '^ *temporal-aq ' <<<"$spec" && found+="t"
    printf -v "$var" '%s' "${found:-none}"
    export "${var?}"
    [ -n "$spec" ] && _probe_cache_store "$var"
  fi
  case "${!var}" in *s*) props+=" spatial-aq=true" ;; esac
  [ "$mode" = clip ] && case "${!var}" in *t*) props+=" temporal-aq=true" ;; esac
  printf '%s' "$props"
}

# Pick an H.264 encoder fragment. Tries nvcudah264enc, then nvh264enc
# with a probed preset (driver 550+ dropped legacy preset GUIDs so
# strict validation rejects them), then x264enc. Cached in GS_NVENC_PICK
# and the probe cache; override with GS_NVENC_ELEMENT.
# On AMD a VA-API rung sits between nvh264enc and x264enc. Its pick is
# va:<element> (vah264enc, or for example varenderD129h264enc on a second
# render node): it names the element only, so it does not depend on the output
# size. Each call checks the element at GS_ENC_DIMS with _gs_va_ok and, where it
# is not usable at that size, warns and prints the x264enc string instead.
# GS_NVENC_ELEMENT=va forces the rung.
# Usage: pick_h264_pipeline <gop> <kbps> [live|clip]
pick_h264_pipeline() {
  local gop="${1:?gop required}"
  local kbps="${2:?kbps required}"
  local mode="${3:-live}"

  _ensure_nvenc_pick h264

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
      printf 'nvcudah264enc preset=%s tune=%s rate-control=cbr gop-size=%s bitrate=%s%s' \
        "$preset" "$tune" "$gop" "$kbps" "$(_nvenc_aq_props nvcudah264enc "$mode")"
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
    va:*)
      # AMD (S4 C4): the VA element of the pick, used only where _gs_va_ok accepts it
      # at the current output size (GS_ENC_DIMS). Where it does not, today's software
      # string, so the encoder and pick_scale_convert, which runs the same check, fall
      # back together (S4 error [5]).
      local va_el="${GS_NVENC_PICK#va:}" why
      if _gs_va_ok h264 "$va_el"; then
        if [ "$mode" = clip ]; then
          printf '%s rate-control=vbr target-percentage=80 bitrate=%s key-int-max=%s b-frames=0 target-usage=%s' \
            "$va_el" "$kbps" "$gop" "${GS_VA_TARGET_USAGE:-4}"
        else
          printf '%s rate-control=%s target-percentage=95 bitrate=%s cpb-size=%s key-int-max=%s b-frames=0 ref-frames=1 target-usage=%s' \
            "$va_el" "${GS_VA_RATE_CONTROL:-vbr}" "$kbps" "$kbps" "$gop" "${GS_VA_TARGET_USAGE:-4}"
        fi
      else
        why="$(_gs_caps_get h264_reason)"
        warn "VA H.264 encoder not usable at ${GS_ENC_DIMS:-1920x1080} (reason=${why:-?}), using x264enc"
        printf 'x264enc tune=zerolatency speed-preset=veryfast bitrate=%s key-int-max=%s' \
          "$kbps" "$gop"
      fi
      ;;
    *)
      # Nothing resolved: fail here rather than hand back an empty encoder, which
      # turns the pipeline into "! !" and dies at parse time with a vaguer error.
      return 1
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

  # AMD (S4-D3): the VA-API rung, after the NV rungs, which fail fast in an AMD pod (no
  # NVIDIA library is injected there). It does not depend on the output size: the va:
  # arms of the pickers and _active_encoder_is_va run _gs_va_ok at the current size.
  # The pick goes to the probe cache here, since _ensure_nvenc_pick stores only nv*
  # picks. A forced value other than auto or va skips the rung (reason forced-<value>).
  if [ "${GS_GPU_VENDOR:-}" = amd ]; then
    local va_el va_why="forced-$force"
    if [ "$force" = "auto" ] || [ "$force" = "va" ]; then
      if va_el="$(gs_va_element h264enc)"; then
        log "  encoder: $va_el (GPU, VA-API on ${GS_RENDER_NODE:-?})" >&2
        _gs_caps_put h264 "va:$va_el"
        local GS_NVENC_PICK="va:$va_el"
        _probe_cache_store GS_NVENC_PICK
        printf 'va:%s' "$va_el"
        return 0
      fi
      va_why="$(_gs_caps_get element.h264enc)"
      va_why="${va_why#none:}"
    fi
    [ "$(_gs_caps_get h264)" = x264enc ] || _gs_caps_put h264 x264enc
    [ "$(_gs_caps_get h264_reason)" = "$va_why" ] || _gs_caps_put h264_reason "$va_why"
  fi
  [ "$force" = "va" ] && \
    warn "GS_NVENC_ELEMENT=va forced but unavailable"
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

  _ensure_nvenc_pick h265

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
      printf 'nvcudah265enc preset=%s tune=%s rate-control=cbr gop-size=%s bitrate=%s%s' \
        "$preset" "$tune" "$gop" "$h265_kbps" "$(_nvenc_aq_props nvcudah265enc "$mode")"
      ;;
    nvh265enc:*)
      local preset="${GS_NVENC_PICK_H265#nvh265enc:}"
      printf 'nvh265enc preset=%s rc-mode=cbr gop-size=%s bitrate=%s' \
        "$preset" "$gop" "$h265_kbps"
      ;;
    va:*)
      # AMD (S4 C4): HEVC at GS_VA_H265_PCT percent of the H.264 rate (70 by default,
      # the NVIDIA ratio above), used only where _gs_va_ok accepts the element at the
      # current output size (GS_ENC_DIMS). Where it does not, return 1 so the caller
      # falls back to H.264 (S4 error [5]).
      local va_el="${GS_NVENC_PICK_H265#va:}"
      _gs_va_ok h265 "$va_el" || return 1
      h265_kbps=$((kbps * ${GS_VA_H265_PCT:-70} / 100))
      if [ "$mode" = clip ]; then
        printf '%s rate-control=vbr target-percentage=80 bitrate=%s key-int-max=%s b-frames=0 target-usage=%s' \
          "$va_el" "$h265_kbps" "$gop" "${GS_VA_TARGET_USAGE:-4}"
      else
        printf '%s rate-control=%s target-percentage=95 bitrate=%s cpb-size=%s key-int-max=%s b-frames=0 ref-frames=1 target-usage=%s' \
          "$va_el" "${GS_VA_RATE_CONTROL:-vbr}" "$h265_kbps" "$h265_kbps" "$gop" "${GS_VA_TARGET_USAGE:-4}"
      fi
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
  _ensure_nvenc_pick h265
  case "${GS_NVENC_PICK_H265:-none}" in
    none|"") return 1 ;;
    # AMD (S4 C4): a va: pick counts only where _gs_va_ok accepts it at the current
    # output size (GS_ENC_DIMS).
    va:*)    _gs_va_ok h265 "${GS_NVENC_PICK_H265#va:}" ;;
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

  # AMD (S4-D3): the VA-API rung for HEVC, as in _resolve_h264_method. The RDNA4 size
  # rule and the trial run later, in _gs_va_ok. The forced va warning stays behind the
  # vendor test here (S4 C3).
  if [ "${GS_GPU_VENDOR:-}" = amd ]; then
    local va_el va_why="forced-$force"
    if [ "$force" = "auto" ] || [ "$force" = "va" ]; then
      if va_el="$(gs_va_element h265enc)"; then
        log "  encoder: $va_el (GPU, VA-API on ${GS_RENDER_NODE:-?})" >&2
        _gs_caps_put h265 "va:$va_el"
        local GS_NVENC_PICK_H265="va:$va_el"
        _probe_cache_store GS_NVENC_PICK_H265
        printf 'va:%s' "$va_el"
        return 0
      fi
      va_why="$(_gs_caps_get element.h265enc)"
      va_why="${va_why#none:}"
      [ "$force" = "va" ] && \
        warn "GS_NVENC_H265_ELEMENT=va forced but unavailable, falling through"
    fi
    [ "$(_gs_caps_get h265)" = none ] || _gs_caps_put h265 none
    [ "$(_gs_caps_get h265_reason)" = "$va_why" ] || _gs_caps_put h265_reason "$va_why"
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

# Populate the NVENC pick cache for $codec if cold. pick_h26{4,5}_pipeline runs
# in a `$(...)` subshell so its cached export never reaches the parent;
# re-resolve here (same probe, stderr muted) so the scaler's CUDA-vs-CPU choice
# matches the chosen encoder — else the scaler picks CPU for a CUDA encoder.
# Resolve once per pod: the env, then the probe cache, then a real probe. Only GPU
# picks are cached — x264enc / none can be a transient NVENC failure worth retrying.
# Usage: _ensure_nvenc_pick <h264|h265> [quiet]  (quiet mutes the probe's log line)
_ensure_nvenc_pick() {
  local var=GS_NVENC_PICK resolve=_resolve_h264_method pick
  case "${1:-h264}" in
    h265|hevc) var=GS_NVENC_PICK_H265 resolve=_resolve_h265_method ;;
  esac
  _probe_cache_load "$var" && return 0
  if [ "${2:-}" = quiet ]; then
    pick=$("$resolve" 2>/dev/null) || true
  else
    pick=$("$resolve") || true
  fi
  printf -v "$var" '%s' "$pick"
  export "${var?}"
  case "$pick" in nv*) _probe_cache_store "$var" ;; esac
  return 0
}

# True when the resolved NVENC element for $codec is the modern CUDA
# encoder (nvcuda*), which consumes CUDA memory and so must be fed an upload.
# Self-heals a cold cache via _ensure_nvenc_pick so it's correct even when
# called from a different subshell than the one that picked the encoder.
# A VA-API pick (va:<element>, AMD only) is never CUDA, so this is false for it:
# _active_encoder_is_va answers for VA-API, and pick_scale_convert asks it first.
_active_encoder_is_cuda() {
  _ensure_nvenc_pick "${1:-h264}" quiet
  case "${1:-h264}" in
    h265|hevc) [ "${GS_NVENC_PICK_H265:-}" = "nvcudah265enc" ] ;;
    *)         [ "${GS_NVENC_PICK:-}" = "nvcudah264enc" ] ;;
  esac
}

# True when GPU scale+convert is usable: not disabled via GS_GPU_SCALE, and
# both cudaupload + cudaconvertscale exist on this pod. Cached per pod.
_cuda_scale_available() {
  case "${GS_GPU_SCALE:-auto}" in
    0|off|false|no) return 1 ;;
  esac
  if ! _probe_cache_load GS_CUDASCALE_OK; then
    if gst-inspect-1.0 cudaupload >/dev/null 2>&1 \
       && gst-inspect-1.0 cudaconvertscale >/dev/null 2>&1; then
      GS_CUDASCALE_OK=1
    else
      GS_CUDASCALE_OK=0
    fi
    export GS_CUDASCALE_OK
    # Only cache a success: one transient gst-inspect/CUDA failure must not pin the
    # pod to CPU scaling for its whole life.
    [ "$GS_CUDASCALE_OK" = 1 ] && _probe_cache_store GS_CUDASCALE_OK
  fi
  [ "$GS_CUDASCALE_OK" = 1 ]
}

# VA-API encoder helpers (AMD). gs_va_element and the helpers after it return 1, or
# do nothing, unless GS_GPU_VENDOR=amd, and the encoder_caps pair runs only from them
# and from AMD branches, so NVIDIA pods define all of them and never run them. Stdout
# rule, as for the resolvers above: a helper prints only its own result.
# gst-inspect-1.0 and vainfo output is read into variables, trial output is appended
# to encoder_trials.log, and logs go to stderr. Answers are kept in
# ${LOG_DIR}/encoder_caps, append-only key=value lines where the last value for a key
# wins: the file outlives the $(...) subshells the pickers run in, lives as long as
# the pod, and is what capture-info.sh prints.

# Print the last value written for KEY to encoder_caps and return 0, or print nothing
# and return 1 when the key is absent.
# Usage: _gs_caps_get KEY
_gs_caps_get() {
  local key="${1:-}" f="${LOG_DIR:-/tmp/game-streamer}/encoder_caps" line val="" hit=1
  [ -n "$key" ] && [ -r "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) val="${line#"$key="}"; hit=0 ;;
    esac
  done < "$f"
  [ "$hit" = 0 ] || return 1
  printf '%s' "$val"
}

# Append KEY=VALUE to encoder_caps. Never fails its caller: a read-only or full LOG_DIR
# loses the line and nothing else.
# Usage: _gs_caps_put KEY VALUE
_gs_caps_put() {
  local key="${1:-}" val="${2-}" d="${LOG_DIR:-/tmp/game-streamer}"
  [ -n "$key" ] || return 0
  { mkdir -p "$d" && printf '%s=%s\n' "$key" "$val" >> "$d/encoder_caps"; } 2>/dev/null || true
  return 0
}

# Print the VA element of <kind> that drives GS_RENDER_NODE and return 0, or print
# nothing and return 1. Candidates in order: va<kind> (vah264enc, vah265enc,
# vapostproc), then va<renderDNNN><kind> from the node's basename (for example
# varenderD129h265enc), the name GStreamer gives the elements of a second device. A
# candidate counts only when the Default of its read-only device-path property is
# GS_RENDER_NODE. Writes element.<kind>=<element>, or none:<reason> with reason
# no-render-node, no-element or device-mismatch, and answers later calls from it. The
# first call also records vendor, render_node and pci.
# Usage: gs_va_element <h264enc|h265enc|postproc>
gs_va_element() {
  local kind="${1:-}" node="${GS_RENDER_NODE:-}" cached el spec line dev in_prop
  local found="" reason=no-render-node re='Default: "([^"]*)"'
  [ "${GS_GPU_VENDOR:-}" = amd ] && [ -n "$kind" ] || return 1
  if ! _gs_caps_get vendor >/dev/null; then
    _gs_caps_put vendor amd
    _gs_caps_put render_node "$node"
    _gs_caps_put pci "${GS_GPU_PCI_ADDRESS:-}"
  fi
  if cached="$(_gs_caps_get "element.$kind")"; then
    case "$cached" in
      none:*|"") return 1 ;;
    esac
    printf '%s' "$cached"
    return 0
  fi
  if [ -n "$node" ] && [ -c "$node" ]; then
    reason=no-element
    for el in "va$kind" "va${node##*/}$kind"; do
      spec="$(gst-inspect-1.0 "$el" 2>/dev/null)" || continue
      dev="" in_prop=0
      while IFS= read -r line; do
        if [ "$in_prop" = 0 ]; then
          [[ "$line" =~ ^[[:space:]]*device-path[[:space:]]*: ]] || continue
          in_prop=1
        elif [[ "$line" =~ ^[[:space:]]{2}[^[:space:]] ]]; then
          break
        fi
        if [[ "$line" =~ $re ]]; then
          dev="${BASH_REMATCH[1]}"
          break
        fi
      done <<< "$spec"
      if [ "$dev" = "$node" ]; then
        found="$el"
        break
      fi
      reason=device-mismatch
    done
  fi
  if [ -z "$found" ]; then
    _gs_caps_put "element.$kind" "none:$reason"
    return 1
  fi
  _gs_caps_put "element.$kind" "$found"
  printf '%s' "$found"
}

# Run one trial pipeline: gst-launch-1.0 -q with the arguments given, under
# timeout -k 5 20, its output appended to encoder_trials.log (dropped when that file
# cannot be written). Retried once unless it timed out (rc 124 or 137). Caches
# KEY=ok|fail:<rc>; 0 when it passed. The timeout ends only a user-space hang: a
# process blocked in the kernel on a VCN fence is ended by the amdgpu job timeout and a
# GPU reset alone (S4-D5).
# Usage: _gs_va_launch KEY GST-ARG...
_gs_va_launch() {
  local key="${1:-}" tlog="${LOG_DIR:-/tmp/game-streamer}/encoder_trials.log" rc=1 n
  shift
  { mkdir -p "${tlog%/*}" && : >> "$tlog"; } 2>/dev/null || tlog=/dev/null
  for n in 1 2; do
    printf '== %s (run %s)\n' "$key" "$n" >> "$tlog" 2>/dev/null
    timeout -k 5 20 gst-launch-1.0 -q "$@" < /dev/null >> "$tlog" 2>&1
    rc=$?
    case "$rc" in
      0|124|137) break ;;
    esac
  done
  if [ "$rc" = 0 ]; then
    _gs_caps_put "$key" ok
    return 0
  fi
  _gs_caps_put "$key" "fail:$rc"
  return 1
}

# One-frame trial of a VA encoder at <WxH> (S4-D5): a videotestsrc frame through the VA
# postproc (when one resolves) and the encoder with the fixed trial properties. Cached
# for the pod's life as trial.<codec>.<element>.<WxH>; 0 when the frame was encoded.
# Usage: _gs_va_trial <h264|h265> <element> <WxH>
_gs_va_trial() {
  local codec="${1:-}" el="${2:-}" dims="${3:-}" key cached pp parse=h264parse
  local -a feed
  [ "${GS_GPU_VENDOR:-}" = amd ] || return 1
  key="trial.$codec.$el.$dims"
  if cached="$(_gs_caps_get "$key")"; then
    [ "$cached" = ok ]
    return
  fi
  [ "$codec" = h265 ] && parse=h265parse
  if pp="$(gs_va_element postproc)"; then
    feed=(videotestsrc num-buffers=1
      ! "video/x-raw,format=BGRA,width=${dims%x*},height=${dims#*x},framerate=60/1"
      ! "$pp" ! "video/x-raw(memory:VAMemory),format=NV12")
  else
    feed=(videotestsrc num-buffers=1
      ! "video/x-raw,format=NV12,width=${dims%x*},height=${dims#*x},framerate=60/1")
  fi
  _gs_va_launch "$key" "${feed[@]}" ! "$el" rate-control=vbr target-percentage=95 \
    bitrate=8000 cpb-size=8000 key-int-max=120 b-frames=0 ref-frames=1 \
    "target-usage=${GS_VA_TARGET_USAGE:-4}" ! "$parse" ! fakesink sync=false
}

# Print the GPU's family token, lowercased (gfx1151, navi31, polaris10 and so on): the
# word after '(radeonsi, ' in vainfo's driver string unless it is a compiler name (llvm,
# aco), else the word after '(RADV ' in the name field of gpu_identity. Prints nothing
# when neither has one. Caches gfx, and device_id from gpu_identity.
# Usage: _gs_va_gfx
_gs_va_gfx() {
  local gfx="" out="" line name="" did="" id="${LOG_DIR:-/tmp/game-streamer}/gpu_identity"
  local re_si='\(radeonsi, ([^,)]*)' re_radv='\(radv ([^)]*)\)'
  [ "${GS_GPU_VENDOR:-}" = amd ] || return 1
  if gfx="$(_gs_caps_get gfx)"; then
    printf '%s' "$gfx"
    return 0
  fi
  gfx=""
  if [ -n "${GS_RENDER_NODE:-}" ]; then
    out="$(vainfo --display drm --device "$GS_RENDER_NODE" 2>/dev/null)" || true
  fi
  out="${out,,}"
  if [[ "$out" =~ $re_si ]]; then
    gfx="${BASH_REMATCH[1]// /}"
    case "$gfx" in
      llvm*|aco) gfx="" ;;
    esac
  fi
  if [ -r "$id" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        name=*) name="${line#name=}" ;;
        device_id=*) did="${line#device_id=}" ;;
      esac
    done < "$id"
  fi
  name="${name,,}"
  if [ -z "$gfx" ] && [[ "$name" =~ $re_radv ]]; then
    gfx="${BASH_REMATCH[1]// /}"
  fi
  _gs_caps_put gfx "$gfx"
  _gs_caps_put device_id "$did"
  printf '%s' "$gfx"
}

# HEVC size rule (S4-D14): RDNA4 VCN hangs on sizes whose 16-aligned width or height is
# not a multiple of 64. For such a size, prints the reason and returns 1 when the family
# token is gfx12* (rdna4-dpb-size) or unknown (gfx-unknown-dpb-size); else 0.
# Usage: _gs_va_rdna4_size_ok <WxH>
_gs_va_rdna4_size_ok() {
  local dims="${1:-1920x1080}" aw ah
  [ "${GS_GPU_VENDOR:-}" = amd ] || return 1
  [[ "$dims" =~ ^[0-9]+x[0-9]+$ ]] || dims=1920x1080
  aw=$(( (${dims%x*} + 15) / 16 * 16 ))
  ah=$(( (${dims#*x} + 15) / 16 * 16 ))
  [ $(( aw % 64 )) = 0 ] && [ $(( ah % 64 )) = 0 ] && return 0
  case "$(_gs_va_gfx)" in
    gfx12*) printf 'rdna4-dpb-size'; return 1 ;;
    "") printf 'gfx-unknown-dpb-size'; return 1 ;;
  esac
  return 0
}

# The one gate for using a VA element at the current output size (GS_ENC_DIMS, unset
# means 1920x1080), in order: a pre-VCN family token refuses both codecs with no trial
# (pre-vcn-unsoaked); for HEVC the RDNA4 size rule; then the one-frame trial at the size
# raised to at least 640x480. Writes h264_reason or h265_reason (ok, or why not) when it
# changes. 0 when the element may be used.
# Usage: _gs_va_ok <h264|h265> <element>
_gs_va_ok() {
  local codec="${1:-}" el="${2:-}" dims="${GS_ENC_DIMS:-1920x1080}" w h reason=ok
  [ "${GS_GPU_VENDOR:-}" = amd ] || return 1
  [[ "$dims" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]] || dims=1920x1080
  case "$(_gs_va_gfx)" in
    tahiti|pitcairn|verde|oland|hainan|bonaire|kaveri|kabini|hawaii|tonga|iceland \
      |carrizo|fiji|stoney|polaris10|polaris11|polaris12|vegam|vega10|vega12|vega20)
      reason=pre-vcn-unsoaked ;;
  esac
  if [ "$reason" = ok ] && [ "$codec" = h265 ]; then
    if reason="$(_gs_va_rdna4_size_ok "$dims")"; then reason=ok; fi
  fi
  if [ "$reason" = ok ]; then
    w="${dims%x*}" h="${dims#*x}"
    [ "$w" -lt 640 ] && w=640
    [ "$h" -lt 480 ] && h=480
    if ! _gs_va_trial "$codec" "$el" "${w}x$h"; then
      case "$(_gs_caps_get "trial.$codec.$el.${w}x$h")" in
        fail:124|fail:137) reason=trial-timeout ;;
        *) reason=trial-fail ;;
      esac
    fi
  fi
  [ "$(_gs_caps_get "${codec}_reason")" = "$reason" ] || _gs_caps_put "${codec}_reason" "$reason"
  [ "$reason" = ok ]
}

# Scale trial (S4 interface [3]), for a capture size that differs from the output size:
# two BGRA frames at <srcWxH> through the VA postproc, scaled to <outWxH> NV12, into the
# encoder with the trial properties. The timeout, log, retry and cache rules of the
# one-frame trial, cached as scale.<element>.<src>.<out>. 0 when the frames were
# encoded; 1 with no trial when no VA postproc resolves.
# Usage: _gs_va_scale_ok <h264|h265> <element> <srcWxH> <outWxH>
_gs_va_scale_ok() {
  local codec="${1:-}" el="${2:-}" src="${3:-}" dst="${4:-}" key cached pp parse=h264parse
  [ "${GS_GPU_VENDOR:-}" = amd ] || return 1
  key="scale.$el.$src.$dst"
  if cached="$(_gs_caps_get "$key")"; then
    [ "$cached" = ok ]
    return
  fi
  pp="$(gs_va_element postproc)" || return 1
  [ "$codec" = h265 ] && parse=h265parse
  _gs_va_launch "$key" videotestsrc num-buffers=2 \
    ! "video/x-raw,format=BGRA,width=${src%x*},height=${src#*x},framerate=60/1" ! "$pp" \
    ! "video/x-raw(memory:VAMemory),format=NV12,width=${dst%x*},height=${dst#*x}" \
    ! "$el" rate-control=vbr target-percentage=95 bitrate=8000 cpb-size=8000 \
    key-int-max=120 b-frames=0 ref-frames=1 "target-usage=${GS_VA_TARGET_USAGE:-4}" \
    ! "$parse" ! fakesink sync=false
}

# True when the active encoder for <codec> is a VA element that _gs_va_ok accepts at
# the current GS_ENC_DIMS, so pick_scale_convert always matches the encoder across
# subshells and sizes. Returns 1 before any probe unless GS_GPU_VENDOR=amd.
# Usage: _active_encoder_is_va <h264|h265>
_active_encoder_is_va() {
  local codec=h264 pick
  [ "${GS_GPU_VENDOR:-}" = amd ] || return 1
  case "${1:-h264}" in
    h265|hevc) codec=h265 ;;
  esac
  _ensure_nvenc_pick "$codec" quiet
  pick="${GS_NVENC_PICK:-}"
  [ "$codec" = h265 ] && pick="${GS_NVENC_PICK_H265:-}"
  case "$pick" in
    va:*) _gs_va_ok "$codec" "${pick#va:}" ;;
    *) return 1 ;;
  esac
}

# One ENCODER-CAPS line per capture mode (S4-D6), from the caller's parent shell after
# the pipeline is built, never inside $(...): mode, requested and actual codec, the
# encoder element, the render node, the gfx token, the PCI device id, the scaler and the
# reason. A WARN when the codec fell back or the encoder is software (x264enc for live
# and clips, libx264 for inline renders). The sixth argument sets the reason (inline
# renders pass it); otherwise it comes from encoder_caps. Also writes requested.<mode>,
# actual.<mode> and reason.<mode> to encoder_caps.
# Usage: gs_encoder_status <live|clip|inline> <requested codec> <actual codec> <encoder string> <convert string> [<reason>]
gs_encoder_status() {
  [ "${GS_GPU_VENDOR:-}" = amd ] || return 0
  local mode="${1:-}" req="${2:-}" act="${3:-}" enc="${4:-}" conv="${5:-}" reason="${6:-}"
  local el gfx did scaler=cpu msg
  el="${enc%% *}"
  case "$conv" in
    *vapostproc*) scaler=vapostproc ;;
  esac
  if [ -z "$reason" ]; then
    if [ "$act" != "$req" ]; then
      reason="$(_gs_caps_get "${req}_reason")"
    elif [ "$el" = x264enc ] || [ "$el" = libx264 ]; then
      reason="$(_gs_caps_get "${act}_reason")"
    elif [ "$scaler" = cpu ] && [ "${el#va}" != "$el" ] \
      && [[ "$(_gs_caps_get "scale.$el.${CS2_DISPLAY_RES:-1920x1080}.${GS_ENC_DIMS:-1920x1080}")" == fail:* ]]; then
      reason=va-scale-fail
    else
      reason=ok
    fi
  fi
  [ -n "$reason" ] || reason='?'
  gfx="$(_gs_va_gfx)"
  did="$(_gs_caps_get device_id)"
  _gs_caps_put "requested.$mode" "$req"
  _gs_caps_put "actual.$mode" "$act"
  _gs_caps_put "reason.$mode" "$reason"
  msg="ENCODER-CAPS: mode=$mode requested=$req actual=$act encoder=${el:-?} device=${GS_RENDER_NODE:-?} gfx=${gfx:-?} device_id=${did:-?} scaler=$scaler reason=$reason"
  if [ "$act" != "$req" ] || [ "$el" = x264enc ] || [ "$el" = libx264 ]; then
    warn "$msg"
  else
    log "$msg"
  fi
  return 0
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
# On AMD a VA-API encoder (_active_encoder_is_va) gets the VA branch first:
# videorate, then the render node's VA postproc (vapostproc) scales and converts
# to NV12 in VA memory. Its capsfilter ends the fragment, so the encoder follows
# it directly and a same-size convert folds into the encoder (EFC). With GPU
# scaling off (GS_GPU_SCALE), no postproc on the node or a failed scale trial,
# the fragment is videorate plus the CPU one, and the encoder stays VA-API.
# Usage: pick_scale_convert <out_w> <out_h> <fps> <codec>
pick_scale_convert() {
  local w="${1:?width required}" h="${2:?height required}"
  local fps="${3:?fps required}" codec="${4:-h264}"
  local cpu="videoscale ! video/x-raw,width=${w},height=${h},framerate=${fps}/1 ! videoconvert ! video/x-raw,format=NV12"
  # AMD (S4-D8): a VA-API encoder gets the scale and the RGB to NV12 convert from the VA
  # postproc, behind videorate (videorate first avoids the synthetic PTS of the
  # GStreamer 1.24.2 va elements). The postproc capsfilter ends the fragment, so nothing
  # sits between it and the encoder, and a same-size convert folds into the encoder
  # (EFC). The CPU fragment, behind the same videorate, when GS_GPU_SCALE turns GPU
  # scaling off, when no VA postproc drives the render node, or when the capture size
  # (CS2_DISPLAY_RES) differs from the output and the scale trial fails (reason
  # va-scale-fail): the encoder stays VA either way. Writes scaler=vapostproc|cpu to
  # encoder_caps when it changes.
  if _active_encoder_is_va "$codec"; then
    local c=h264 el pp="" src="${CS2_DISPLAY_RES:-1920x1080}"
    case "$codec" in
      h265|hevc) c=h265 el="${GS_NVENC_PICK_H265:-}" ;;
      *) el="${GS_NVENC_PICK:-}" ;;
    esac
    el="${el#va:}"
    case "${GS_GPU_SCALE:-auto}" in
      0|off|false|no) ;;
      *) pp="$(gs_va_element postproc)" || pp="" ;;
    esac
    if [ -n "$pp" ] && [ "$src" != "${w}x${h}" ] \
      && ! _gs_va_scale_ok "$c" "$el" "$src" "${w}x${h}"; then
      pp=""
    fi
    if [ -n "$pp" ]; then
      [ "$(_gs_caps_get scaler)" = vapostproc ] || _gs_caps_put scaler vapostproc
      log "  scaler: vapostproc (VA scale+convert)" >&2
      printf 'videorate ! video/x-raw,framerate=%s/1 ! %s ! video/x-raw(memory:VAMemory),format=NV12,width=%s,height=%s,framerate=%s/1' \
        "$fps" "$pp" "$w" "$h" "$fps"
      return 0
    fi
    [ "$(_gs_caps_get scaler)" = cpu ] || _gs_caps_put scaler cpu
    log "  scaler: CPU videoscale+videoconvert" >&2
    printf 'videorate ! %s' "$cpu"
    return 0
  fi
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
# On AMD it also guards EFC for a VA-API encoder (va*enc*): between the last
# vapostproc and the encoder only the postproc capsfilter may sit, and any other
# element there gets a BUG warning (warn only). AMD_DEBUG=noefc, Mesa's own
# switch, turns EFC off for A/B tests in a dev pod only.
_assert_cuda_chain() {
  case "$2" in
    *nvcudah264enc*|*nvcudah265enc*)
      case "$1" in
        *cudaupload*|*CUDAMemory*) ;;
        *) warn "BUG: CUDA encoder fed non-CUDA memory — pick_scale_convert must precede the encoder (convert='$1')" ;;
      esac ;;
    # AMD (S4 C6): a VA encoder must follow vapostproc and its capsfilter directly, or
    # a same-size convert no longer folds into the encoder (EFC). Warn only.
    va*enc*)
      [ "${GS_GPU_VENDOR:-}" = amd ] || return 0
      case "$1" in
        *vapostproc*)
          case "${1##*vapostproc}" in
            *'!'*'!'*) warn "BUG: an element sits between vapostproc and the VA encoder, which breaks EFC (convert=$1)" ;;
          esac ;;
      esac ;;
  esac
}

# obs-vkcapture present-hook needs nvidia-drm modeset on (its dmabuf sharing).
# True unless we have POSITIVE evidence it's off — the host kernel param is visible
# via the shared /sys; unreadable/absent -> assume on (don't block the default path
# on a missing sysfs).
# AMD hosts load no nvidia_drm module, so the parameter file is absent: the
# check below returns 0 and vkcapture stays available there.
_drm_modeset_on() {
  local f=/sys/module/nvidia_drm/parameters/modeset v
  [ -r "$f" ] || return 0
  v=$(cat "$f" 2>/dev/null)
  [ "$v" != "N" ] && [ "$v" != "0" ]
}

# CPU split between cs2 and the capture pipeline. Pinning the capture consumer to
# the top cores only ISOLATES it if cs2 is confined to the complementary cores —
# otherwise cs2's threads still schedule onto the capture cores and the two fight
# (which jitters cs2's present + starves its audio thread → the frame/audio
# hitch). This computes one consistent split: capture gets the top CAPTURE_CORES
# cores (default 2), cs2 gets the rest. Sets GS_CAPTURE_CPUS + GS_CS2_CPUS (taskset
# -c lists). Env overrides win: pre-set CAPTURE_CPUS / CS2_CPUS are honored as-is;
# empty string = "don't pin this side". Only splits on a box with ≥4 cores (below
# that, carving out cores starves cs2 more than contention does). Idempotent.
compute_cpu_split() {
  [ -n "${GS_CPU_SPLIT_DONE:-}" ] && return 0
  local ncpu capn caphi caplo
  ncpu=$(nproc 2>/dev/null || echo 0)
  if [ "$ncpu" -ge 4 ]; then
    capn="${CAPTURE_CORES:-2}"
    [ "$capn" -lt 1 ] && capn=1
    [ "$capn" -ge "$ncpu" ] && capn=$(( ncpu - 1 ))
    caplo=$(( ncpu - capn )); caphi=$(( ncpu - 1 ))
    # `+x` test: only fill in a side the caller didn't explicitly set (even to "").
    # Capture pin: status quo from ≥4 cores. cs2 pin: only once there are enough
    # cores that confining cs2 still leaves it a healthy share — below
    # GS_CS2_PIN_MIN_CORES (default 6 → cs2 keeps ≥4) we'd hand heavily-threaded
    # cs2 too few exclusive cores, which hurts more than the contention it removes.
    [ -z "${CAPTURE_CPUS+x}" ] && CAPTURE_CPUS="${caplo}-${caphi}"
    # Streams (not clip batches) also run the HUD (Electron), spec-server and picom
    # all the time; give them AUX_CORES (default 1) just below the capture cores so
    # they stop preempting cs2. Only with ≥ GS_AUX_PIN_MIN_CORES (10) cores.
    local auxn=0
    if [ -z "${AUX_CPUS+x}" ] && [ "${CLIP_BATCH_MODE:-0}" != "1" ] \
       && [ "$ncpu" -ge "${GS_AUX_PIN_MIN_CORES:-10}" ]; then
      auxn="${AUX_CORES:-1}"
      [ "$auxn" -ge 1 ] && AUX_CPUS="$(( caplo - auxn ))-$(( caplo - 1 ))"
    fi
    if [ -z "${CS2_CPUS+x}" ] && [ "$ncpu" -ge "${GS_CS2_PIN_MIN_CORES:-6}" ]; then
      CS2_CPUS="0-$(( caplo - auxn - 1 ))"
    fi
  fi
  GS_CAPTURE_CPUS="${CAPTURE_CPUS:-}"
  GS_CS2_CPUS="${CS2_CPUS:-}"
  GS_AUX_CPUS="${AUX_CPUS:-}"
  GS_CPU_SPLIT_DONE=1
  export GS_CAPTURE_CPUS GS_CS2_CPUS GS_AUX_CPUS GS_CPU_SPLIT_DONE CAPTURE_CPUS CS2_CPUS AUX_CPUS
}

# Set the CPU affinity of <pid>, every thread of it, and all its descendants.
# Threads and children created later inherit it. Usage: pin_pid_tree <cpus> <pid>
pin_pid_tree() {
  local cpus="$1" pid="$2" kid
  [ -n "$cpus" ] && [ -n "$pid" ] && command -v taskset >/dev/null 2>&1 || return 0
  taskset -a -p -c "$cpus" "$pid" >/dev/null 2>&1 || return 0
  for kid in $(pgrep -P "$pid" 2>/dev/null); do pin_pid_tree "$cpus" "$kid"; done
}

# Apply the CPU split to the running processes. cs2 is started by the already-running
# Steam client (-applaunch just forwards the command line and exits), so wrapping
# the launch in taskset never reached it: cs2 ran on every core, capture cores
# included. Pin it — and, on streams, the HUD/spec-server/picom — once it's up.
apply_cpu_split() {
  compute_cpu_split
  local cs2
  cs2=$(pgrep -f '/linuxsteamrt64/cs2' | head -1)
  if [ -n "$cs2" ] && [ -n "$GS_CS2_CPUS" ]; then
    pin_pid_tree "$GS_CS2_CPUS" "$cs2"
    log "cpu split: cs2 (pid $cs2) -> cores $GS_CS2_CPUS"
  fi
  pin_aux_procs
}

# Move the HUD (Electron) and picom onto the AUX core. Not spec-server: affinity is
# inherited, and it starts on-demand clip renders (routes/render-clip.mjs) and
# switch-match.sh, which would then capture, render the chip and encode on that one
# core. Also called when the HUD respawns (position_hud_overlay).
pin_aux_procs() {
  compute_cpu_split
  [ -n "$GS_AUX_CPUS" ] || return 0
  local p n=0
  for p in $(pgrep -f '[j]ts-hud-manager') $(pgrep -x picom); do
    pin_pid_tree "$GS_AUX_CPUS" "$p"; n=$((n + 1))
  done
  log "cpu split: HUD/picom ($n procs) -> cores $GS_AUX_CPUS; capture -> ${GS_CAPTURE_CPUS:-all}"
}

# taskset prefix array for cs2: confines cs2 to GS_CS2_CPUS so it never shares a
# core with the capture pipeline. Usage: read into an array, prepend to the launch
# cmd. Empty (no-op) when taskset is missing or the split decided not to pin.
cs2_cpu_pin() {
  compute_cpu_split
  if [ -n "${GS_CS2_CPUS:-}" ] && command -v taskset >/dev/null 2>&1; then
    printf 'taskset\n-c\n%s\n' "$GS_CS2_CPUS"
  fi
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
