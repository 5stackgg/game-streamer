# shellcheck shell=bash
# shellcheck disable=SC2016  # the stub bodies and the es_sh scripts expand when they run
# Runners for the encode call sites in src/lib/stream.sh and src/lib/clip-capture.sh,
# sourced by test/amd/encode-pick.sh after harness.sh and golden.sh. Every program the
# sites probe or spawn is a stub: gst-launch-1.0 -e and vkcapture-consumer only record
# their argv and sleep, so no pipeline ever runs.

ES_DASH="$(printf '\342\200\224')"

# es_case NAME: t_case, then the stubs. Their switches, passed as VAR=VALUE pairs:
#   T_GST_ELEMENTS  the elements gst-inspect-1.0 knows (unset: the NVIDIA set below)
#   T_GST_PROBE_RC  the exit status of every gst-launch-1.0 -q probe (default 0)
#   T_VKCAP_DIES=1  vkcapture-consumer exits at once
#   T_CS2_UP=0      pgrep finds no cs2 process
es_case() {
  t_case "$1"
  t_stub gst-inspect-1.0 'case " ${T_GST_ELEMENTS-nvcudah264enc nvcudah265enc cudaupload cudaconvertscale} " in
  *" ${1:-} "*) ;;
  *) exit 1 ;;
esac
printf "%s\n" "Element Properties:" \
  "  spatial-aq          : Spatial adaptive quantization" \
  "  temporal-aq         : Temporal adaptive quantization" \
  "  device-path         : DRM device path" \
  "                        flags: readable" \
  "                        String. Default: \"${GS_RENDER_NODE:-}\""'
  t_stub gst-launch-1.0 '[ "${1:-}" = -q ] && exit "${T_GST_PROBE_RC:-0}"
sleep 3'
  t_stub vkcapture-consumer '[ "${T_VKCAP_DIES:-0}" = 1 ] && exit 1
sleep 3'
  t_stub pactl 'printf "1\tcs2.monitor\tmodule-null-sink.c\ts16le 2ch 48000Hz\tIDLE\n"'
  t_stub pgrep 'case "$*" in
  *linuxsteamrt64/cs2*) [ "${T_CS2_UP:-1}" = 1 ] || exit 1; echo 4242 ;;
  *) exit 1 ;;
esac'
  t_stub nvidia-smi 'exit 0'
}

# es_sh LIB [VAR=VALUE ...] -- BODY: sources src/lib/LIB the way the flows source it
# (common.sh first, under set -uo pipefail) in a clean shell, then runs BODY. sleep is
# shortened to 0.2 s, and find_hud_overlay_window answers, so start_capture takes the
# composite path whenever vkcapture-consumer exists and pgrep finds cs2.
es_sh() {
  local lib="$1" pairs=()
  shift
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    pairs+=("$1")
    shift
  done
  shift
  t_run SRT_LATENCY_MS=200 GS_LIVE_DIAG=0 CAPTURE_CPUS= \
    GS_PROBE_CACHE="$T_TMP/gst-probes.env" "${pairs[@]}" -- "set -uo pipefail
. \"\$GS_REPO/src/lib/common.sh\"
. \"\$GS_REPO/src/lib/$lib\"
if [ \"\${GS_GPU_VENDOR:-}\" = amd ] && [ -n \"\${T_GS_RENDER_NODE:-}\" ]; then
  export GS_RENDER_NODE=\"\$T_GS_RENDER_NODE\"
fi
sleep() { command sleep 0.2; }
find_hud_overlay_window() { echo 0x3a00004; }
$1"
}

# es_live [VAR=VALUE ...]: start_capture a1b2c3d4e5f6 at 60 fps and 8000 kbps, with
# audio unless T_AUDIO=0, then prints rc=<status>.
es_live() {
  es_sh stream.sh "$@" -- 'start_capture a1b2c3d4e5f6 60 8000 true "${T_AUDIO:-1}"
echo "rc=$?"'
}

# es_spawned: the recorded argv of every spawned pipeline (vkcapture-consumer and
# gst-launch-1.0 -e), in order.
es_spawned() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "vkcapture-consumer "* | "gst-launch-1.0 -e "*) printf '%s\n' "$line" ;;
    esac
  done < "$T_CALLS"
}

# es_text: stdout, stderr and the spawned pipelines of the last run as one text. The
# upstream U+2014 is written as @EMDASH@, so no golden holds that character.
es_text() {
  local text
  text="--- stdout"$'\n'"$T_STDOUT"$'\n'"--- stderr"$'\n'"$T_STDERR"$'\n'"--- spawned"$'\n'"$(es_spawned)"
  printf '%s' "${text//"$ES_DASH"/@EMDASH@}"
}

# The AMD site cases. ES_AMD holds the switches of a VA-API node: the vendor, the render
# node, the VA picks as part 10's resolver caches them, and the elements gst-inspect-1.0
# knows. Real gs_gpu_env derives the fixture PCI node first; es_sh then uses
# /dev/null as a temporary character-device stand-in because docker has no /dev/dri. The VA
# helpers need a character device whose path the device-path Default printed by
# gst-inspect-1.0 repeats, and the stub prints GS_RENDER_NODE there. Pass ES_AMD first,
# so that later pairs override it: es_live "${ES_AMD[@]}" LIVE_VIDEO_CODEC=h265
# shellcheck disable=SC2034  # read by the test files that source this one
ES_AMD=(GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:c6:00.0 T_GS_RENDER_NODE=/dev/null
  GS_NVENC_PICK=va:vah264enc GS_NVENC_PICK_H265=va:vah265enc
  "T_GST_ELEMENTS=vah264enc vah265enc vapostproc")

# es_amd_case NAME [GFX]: es_case, plus a vainfo stub whose driver line names GFX
# (default gfx1151, the Radeon 8060S).
es_amd_case() {
  es_case "$1"
  t_fake_gpu 0000:c6:00.0 0x1002 0x1586 0x038000 renderD128
  t_stub vainfo "printf '%s\n' 'vainfo: VA-API version: 1.20 (libva 2.20.0)' \\
  'vainfo: Driver version: Mesa Gallium driver 25.2.8-0ubuntu0.24.04.2 for AMD Radeon Graphics (radeonsi, ${2:-gfx1151}, ACO, DRM 3.64, 7.0.0-31-generic)'"
}

# es_caps_lines MODE: the ENCODER-CAPS lines of MODE in the last run's stdout and stderr,
# one per line.
es_caps_lines() {
  printf '%s\n%s\n' "$T_STDOUT" "$T_STDERR" | grep -F "ENCODER-CAPS: mode=$1 " || true
}

# es_pipelines: the spawned pipelines of es_spawned with the %q quoting undone, one per
# line (program name, then its arguments joined by spaces), for plain-text matches.
es_pipelines() {
  local line
  local -a argv
  while IFS= read -r line; do
    eval "argv=($line)"
    printf '%s\n' "${argv[*]}"
  done < <(es_spawned)
}
# es_clip [VAR=VALUE ...]: start_clip_capture "$T_TMP/clip/seg-001.mp4" at 60 fps and
# 16000 kbps, with audio unless T_AUDIO=0, then prints rc=<status> and the two start
# markers the capture sets (t_golden writes $T_TMP as @TMP@). CLIP_OUTPUT_DIMS defaults
# to 1920x1080, because clip-capture.sh reads it with no default; CLIP_CAPTURE_METHOD
# picks the path (default vkcapture).
es_clip() {
  es_sh clip-capture.sh CLIP_OUTPUT_DIMS=1920x1080 "$@" -- 'start_clip_capture "$T_TMP/clip/seg-001.mp4" 60 16000 "${T_AUDIO:-1}"
echo "rc=$? ready=${CLIP_CAPTURE_READY_FILE:-} go=${CLIP_CAPTURE_START_FILE:-}"'
}

# es_clip_gst [VAR=VALUE ...]: es_clip on the ximagesrc path.
es_clip_gst() {
  es_clip CLIP_CAPTURE_METHOD=ximagesrc "$@"
}
