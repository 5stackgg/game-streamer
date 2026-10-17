# Unit tests for the VA-API encode core of src/lib/common.sh: S4 changes C1 to C6, tests
# S4-U1 to S4-U6, S4-U8, S4-U9, S4-U12 to S4-U14 and the picker and scaler half of S4-U7
# (design detail, section 4).
#
# The NVIDIA pickers and the scaler stay byte-identical to the upstream commit: the
# golden_* functions run them with GS_GPU_VENDOR unset (or nvidia where a case says so)
# and NVIDIA stubs, and compare the exit status, stdout, stderr and the gst-inspect-1.0,
# gst-launch-1.0 and vainfo calls with the goldens captured there. Upstream's U+2014 is
# written as @EMDASH@ in the goldens. The AMD cases run after the golden functions and
# never in capture mode.
#
# Every case runs in a fresh shell (t_run) with GS_PROBE_CACHE pointed at a file in its
# own temp dir, because the probe cache (common.sh L142-160) and an exported pick would
# otherwise carry one case's answers into the next.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # t_run scripts and stub bodies expand in the child shell
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=lib/golden.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/golden.sh"

DASH="$(printf '\342\200\224')"

# The gst-inspect-1.0 stub. An element exists when $T_TMP/elements has a line that starts
# with its name; a second word on that line is the Default of the element's read-only
# device-path property. The nvcuda* elements list both AQ properties. GS_TEST_BANNER=1
# adds a banner line on stdout (S4-U14).
INSPECT_STUB='el="${1:-}"
line="$(grep -E "^${el}( |\$)" "$T_TMP/elements" 2>/dev/null | head -n 1)"
[ -n "$line" ] || exit 1
[ -n "${GS_TEST_BANNER:-}" ] && echo "inspect banner: $el"
echo "Factory Details:"
case "$el" in
  nvcuda*) printf "  spatial-aq          : Spatial AQ\n  temporal-aq         : Temporal AQ\n" ;;
esac
dev="${line#"$el"}"
dev="${dev# }"
if [ -n "$dev" ]; then
  printf "  device-path         : DRM device path\n"
  printf "                        flags: readable\n"
  printf "                        String. Default: \"%s\"\n" "$dev"
fi
exit 0'

# elements LINE...: the elements the gst-inspect-1.0 stub knows, one "NAME [DEVICE]" each.
elements() {
  printf '%s\n' "$@" > "$T_TMP/elements"
}

# nv_stubs ELEMENT...: an NVIDIA pod with the named elements, gst-launch-1.0 probes that
# pass, and a vainfo stub that only records its calls.
nv_stubs() {
  t_stub nvidia-smi
  t_stub gst-inspect-1.0 "$INSPECT_STUB"
  t_stub gst-launch-1.0
  t_stub vainfo
  elements "$@"
}

# lib_run [VAR=VALUE ...] SNIPPET: sources src/lib/common.sh in a fresh shell, as the flows
# do, with a probe cache of the case's own, then runs SNIPPET; T_RC is SNIPPET's status.
lib_run() {
  local -a pairs=()
  while [ "$#" -gt 1 ]; do
    pairs+=("$1")
    shift
  done
  t_run "${pairs[@]}" GS_PROBE_CACHE="$T_TMP/gst-probes.env" -- 'set -uo pipefail
SCRIPT_TAG=enc
. "$GS_REPO/src/lib/common.sh"
'"$1"
}

# shot: the exit status, stdout and stderr of the last t_run, then the gst-inspect-1.0,
# gst-launch-1.0 and vainfo calls in order, with U+2014 written as @EMDASH@.
shot() {
  local text calls
  calls="$(grep -E '^(gst-inspect-1[.]0|gst-launch-1[.]0|vainfo)( |$)' "$T_CALLS" || true)"
  text="$(printf 'rc=%s\n== stdout\n%s\n== stderr\n%s\n== calls\n%s' \
    "$T_RC" "$T_STDOUT" "$T_STDERR" "$calls")"
  printf '%s' "${text//"$DASH"/@EMDASH@}"
}

# golden_case KEY [VAR=VALUE ...] SNIPPET: runs SNIPPET with lib_run (stubs already set)
# and compares the shot with the golden KEY.
golden_case() {
  local key="$1"
  shift
  lib_run "$@"
  t_golden "$key" "$(shot)"
}

golden_pickers() {
  local m
  for m in live clip; do
    t_case "nvidia nvcudah264enc $m pick"
    nv_stubs nvcudah264enc cudaupload cudaconvertscale
    golden_case "nvcuda-h264-$m" "pick_h264_pipeline 60 12000 $m"

    t_case "nvidia nvcudah265enc $m pick"
    nv_stubs nvcudah265enc cudaupload cudaconvertscale
    golden_case "nvcuda-h265-$m" "pick_h265_pipeline 60 12000 $m"
  done

  t_case "nvidia nvcudah264enc live pick with GS_GPU_VENDOR=nvidia"
  nv_stubs nvcudah264enc cudaupload cudaconvertscale
  golden_case nvcuda-h264-live-vendor-nvidia GS_GPU_VENDOR=nvidia \
    'pick_h264_pipeline 60 12000 live'

  t_case "nvidia h265_available with nvcudah265enc"
  nv_stubs nvcudah265enc cudaupload cudaconvertscale
  golden_case nvcuda-h265-available 'h265_available'

  t_case "nvidia legacy nvh264enc live pick (first preset refused)"
  nv_stubs nvh264enc
  t_stub gst-launch-1.0 'case "$*" in *"preset=low-latency-hq"*) exit 1 ;; esac
exit 0'
  golden_case nvlegacy-h264-live 'pick_h264_pipeline 60 12000 live'

  t_case "nvidia legacy nvh265enc clip pick"
  nv_stubs nvh265enc
  golden_case nvlegacy-h265-clip 'pick_h265_pipeline 60 12000 clip'

  t_case "software x264enc live pick"
  nv_stubs
  golden_case x264-h264-live 'pick_h264_pipeline 60 12000 live'

  t_case "no hevc encoder"
  nv_stubs
  golden_case x264-h265-none 'pick_h265_pipeline 60 12000 live'

  t_case "no hevc encoder, h265_available"
  nv_stubs
  golden_case x264-h265-available 'h265_available'

  t_case "GS_NVENC_ELEMENT=x264enc forces software"
  nv_stubs nvcudah264enc cudaupload cudaconvertscale
  golden_case forced-x264enc-h264 GS_NVENC_ELEMENT=x264enc 'pick_h264_pipeline 60 12000 live'

  t_case "GS_NVENC_ELEMENT=nvh264enc forced but missing"
  nv_stubs
  golden_case forced-nvh264enc-missing GS_NVENC_ELEMENT=nvh264enc \
    'pick_h264_pipeline 60 12000 clip'

  t_case "GS_NVENC_H265_ELEMENT=nvcudah265enc forced but missing"
  nv_stubs
  golden_case forced-nvcudah265enc-missing GS_NVENC_H265_ELEMENT=nvcudah265enc \
    'pick_h265_pipeline 60 12000 live'

  t_case "unrecognized GS_NVENC_PICK_H265"
  nv_stubs nvcudah265enc cudaupload
  golden_case pick-h265-bogus GS_NVENC_PICK_H265=bogus 'pick_h265_pipeline 60 12000 live'
}

golden_scaler() {
  t_case "nvidia cuda scaler for h264"
  nv_stubs nvcudah264enc cudaupload cudaconvertscale
  golden_case nvcuda-scale-h264 'pick_scale_convert 1920 1080 60 h264'

  t_case "nvidia cuda scaler for h265"
  nv_stubs nvcudah265enc cudaupload cudaconvertscale
  golden_case nvcuda-scale-h265 'pick_scale_convert 1920 1080 60 h265'

  t_case "nvidia cuda scaler with GS_GPU_VENDOR=nvidia"
  nv_stubs nvcudah264enc cudaupload cudaconvertscale
  golden_case nvcuda-scale-h264-vendor-nvidia GS_GPU_VENDOR=nvidia \
    'pick_scale_convert 1920 1080 60 h264'

  t_case "nvidia cuda encoder without cudaconvertscale"
  nv_stubs nvcudah264enc cudaupload
  golden_case nvcuda-noscaler-h264 'pick_scale_convert 1920 1080 60 h264'

  t_case "nvidia cuda encoder with GS_GPU_SCALE=0"
  nv_stubs nvcudah264enc cudaupload cudaconvertscale
  golden_case nvcuda-scale-off-h264 GS_GPU_SCALE=0 'pick_scale_convert 1920 1080 60 h264'

  t_case "nvidia legacy encoder gets the cpu scaler"
  nv_stubs nvh264enc cudaupload cudaconvertscale
  golden_case nvlegacy-scale-h264 'pick_scale_convert 1280 720 60 h264'

  t_case "software encoder gets the cpu scaler"
  nv_stubs
  golden_case x264-scale-h265 'pick_scale_convert 1920 1080 60 h265'

  t_case "cuda chain guard"
  nv_stubs
  golden_case cuda-chain-guard '_assert_cuda_chain "cudaupload ! cudaconvertscale" "nvcudah264enc preset=p4"
_assert_cuda_chain "videoscale ! videoconvert ! video/x-raw,format=NV12" "nvcudah265enc preset=p4"
_assert_cuda_chain "videoscale ! videoconvert" "x264enc tune=zerolatency"'
}

golden_cpu_split() {
  t_case "cpu split on 16 cores"
  nv_stubs
  t_stub nproc 'echo 16'
  golden_case cpu-split-16 'compute_cpu_split
printf "%s|%s|%s\n" "$GS_CAPTURE_CPUS" "$GS_CS2_CPUS" "$GS_AUX_CPUS"'
}

golden_pickers
golden_scaler
golden_cpu_split
# shellcheck source=lib/encode-sites.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/encode-sites.sh"

# S4-U7, stream.sh (part 11): NVIDIA byte-identity of start_capture's pipeline strings
# and log lines (vendor unset, NVIDIA stubs).
golden_stream_sites() {
  es_case "S4-U7 stream.sh: composite, h264, audio"
  es_live
  t_golden stream-composite-h264 "$(es_text)"

  es_case "S4-U7 stream.sh: composite, h265 at 1280x720, no audio"
  es_live LIVE_VIDEO_CODEC=h265 LIVE_OUTPUT_DIMS=1280x720 T_AUDIO=0
  t_golden stream-composite-h265-720p "$(es_text)"

  es_case "S4-U7 stream.sh: hevc without nvcudah265enc falls back to h264"
  es_live LIVE_VIDEO_CODEC=hevc T_GST_ELEMENTS="nvcudah264enc cudaupload cudaconvertscale"
  t_golden stream-h265-fallback "$(es_text)"

  es_case "S4-U7 stream.sh: unknown codec, no cs2, ximagesrc with audio"
  es_live LIVE_VIDEO_CODEC=av1 T_CS2_UP=0
  t_golden stream-ximagesrc-audio "$(es_text)"

  es_case "S4-U7 stream.sh: composite consumer dies on spawn, ximagesrc without audio"
  es_live T_VKCAP_DIES=1 T_AUDIO=0
  t_golden stream-composite-died "$(es_text)"

  es_case "S4-U7 stream.sh: no NVIDIA element, x264enc and the CPU scaler"
  es_live T_GST_ELEMENTS=
  t_golden stream-x264-cpu "$(es_text)"
}
golden_stream_sites

# S4-U7, clip-capture.sh (part 11): NVIDIA byte-identity of the clip capture pipelines
# and log lines on the vkcapture and the ximagesrc paths (vendor unset, NVIDIA stubs).
golden_clip_sites() {
  es_case "S4-U7 clip-capture.sh: vkcapture, h264, audio"
  es_clip
  t_golden clip-vk-h264-audio "$(es_text)"

  es_case "S4-U7 clip-capture.sh: vkcapture, h265 at 1280x720, zero-copy, no audio"
  es_clip CLIP_VIDEO_CODEC=h265 CLIP_OUTPUT_DIMS=1280x720 CLIP_ZEROCOPY=1 T_AUDIO=0
  t_golden clip-vk-h265-720p-zerocopy "$(es_text)"

  es_case "S4-U7 clip-capture.sh: hevc without nvcudah265enc falls back to h264"
  es_clip CLIP_VIDEO_CODEC=hevc T_GST_ELEMENTS="nvcudah264enc cudaupload cudaconvertscale"
  t_golden clip-vk-h265-fallback "$(es_text)"

  es_case "S4-U7 clip-capture.sh: unknown codec, no NVIDIA element, zero-copy refused"
  es_clip CLIP_VIDEO_CODEC=av1 CLIP_ZEROCOPY=1 T_GST_ELEMENTS=
  t_golden clip-vk-x264-zerocopy-refused "$(es_text)"

  es_case "S4-U7 clip-capture.sh: zero-copy consumer dies twice, ximagesrc with audio"
  es_clip CLIP_ZEROCOPY=1 T_VKCAP_DIES=1
  t_golden clip-vk-died-gst-audio "$(es_text)"

  es_case "S4-U7 clip-capture.sh: ximagesrc, h264, no audio"
  es_clip_gst T_AUDIO=0
  t_golden clip-gst-h264 "$(es_text)"
}
golden_clip_sites

# shellcheck source=lib/inline-codec.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/inline-codec.sh"

# S4-U7, inline-clip-render.sh (part 11): NVIDIA byte-identity of the P2 inline codec
# choice: the 'final encode' line and the other say lines, the encoder args it leaves
# for the encode sites and the ffmpeg probes it runs (vendor unset, NVIDIA stubs).
golden_inline_codec() {
  ic_case "S4-U7 inline codec choice: h264, h264_nvenc with B-frame refs"
  ic_run
  t_golden inline-codec-h264-nvenc "$(ic_text)"

  ic_case "S4-U7 inline codec choice: h264_nvenc without B-frame refs, own rates"
  ic_run T_FF_FULL_RC=1 CLIP_FINAL_BITRATE=12M CLIP_FINAL_MAXRATE=20M CLIP_FINAL_BUFSIZE=24M
  t_golden inline-codec-h264-nobref "$(ic_text)"

  ic_case "S4-U7 inline codec choice: both h264_nvenc test encodes fail, libx264"
  ic_run T_FF_FULL_RC=1 T_FF_NOBREF_RC=1
  t_golden inline-codec-h264-x264 "$(ic_text)"

  ic_case "S4-U7 inline codec choice: CLIP_FINAL_ENCODER=x264 and an unknown codec"
  ic_run CLIP_FINAL_ENCODER=x264 CLIP_VIDEO_CODEC=av1
  t_golden inline-codec-x264-forced "$(ic_text)"

  ic_case "S4-U7 inline codec choice: h265 on gstreamer and ffmpeg NVENC"
  ic_run CLIP_VIDEO_CODEC=h265
  t_golden inline-codec-h265-nvenc "$(ic_text)"

  ic_case "S4-U7 inline codec choice: hevc, ffmpeg lists no hevc_nvenc, h264"
  ic_run CLIP_VIDEO_CODEC=hevc T_FF_HEVC=0
  t_golden inline-codec-h265-no-ffmpeg "$(ic_text)"

  ic_case "S4-U7 inline codec choice: h265 without a gstreamer NVENC HEVC element, h264"
  ic_run CLIP_VIDEO_CODEC=h265 T_GST_ELEMENTS="nvcudah264enc cudaupload cudaconvertscale"
  t_golden inline-codec-h265-no-gst "$(ic_text)"
}
golden_inline_codec

if t_capture_mode; then t_done; fi

# The AMD cases follow; they never run in capture mode.
# New cases go right above the final t_done.
# AMD helpers. The VA-API node's vendor, render node and PCI address are exported by
# amd_run after common.sh is sourced, so nothing that runs at source time can change
# them. The render node is /dev/null unless GS_TEST_NODE says otherwise: the docker run
# has no /dev/dri, and the VA helpers need a character device whose path the
# device-path Default printed by the gst-inspect-1.0 stub repeats.
VA_ALL=("vah264enc /dev/null" "vah265enc /dev/null" "vapostproc /dev/null")
VA_CONV='videorate ! video/x-raw,framerate=60/1 ! vapostproc ! video/x-raw(memory:VAMemory),format=NV12,width=1920,height=1080,framerate=60/1'
CPU_CONV='videorate ! videoscale ! video/x-raw,width=1920,height=1080,framerate=60/1 ! videoconvert ! video/x-raw,format=NV12'

# amd_stubs ELEMENT...: an AMD pod. gst-inspect-1.0 knows the elements given (see
# elements), gst-launch-1.0 runs pass, vainfo prints a radeonsi driver line with the
# family token held in $T_TMP/gfx (gfx1151 when that file is absent), gpu_identity
# names the Radeon 8060S, and there is no nvidia-smi. GS_TEST_BANNER=1 makes vainfo
# print a banner line first (S4-U14).
amd_stubs() {
  t_stub gst-inspect-1.0 "$INSPECT_STUB"
  t_stub gst-launch-1.0
  t_stub vainfo 'gfx="$(cat "$T_TMP/gfx" 2>/dev/null || echo gfx1151)"
[ -n "${GS_TEST_BANNER:-}" ] && echo "vainfo banner"
echo "vainfo: Driver version: Mesa Gallium driver 25.2.8 for AMD Radeon Graphics (radeonsi, $gfx, ACO, DRM 3.64, 7.0.0-31-generic)"'
  printf '%s\n' 'name=AMD Radeon 8060S Graphics (RADV GFX1151)' vendor_id=0x1002 \
    device_id=0x1586 pci_address=0000:c6:00.0 > "$LOG_DIR/gpu_identity"
  elements "$@"
}

# amd_run [VAR=VALUE ...] SNIPPET: lib_run on the AMD node.
amd_run() {
  local -a pairs=("${@:1:$#-1}")
  lib_run "${pairs[@]}" 'export GS_GPU_VENDOR=amd GS_RENDER_NODE="${GS_TEST_NODE-/dev/null}" GS_GPU_PCI_ADDRESS=0000:c6:00.0
'"${*: -1}"
}

# The trial properties of S4-D5, without target-usage.
VA_TRIAL_PROPS=(rate-control=vbr target-percentage=95 bitrate=8000 cpb-size=8000 key-int-max=120
  b-frames=0 ref-frames=1)

# qargs ARG...: the ARGs as t_stub records them, each printf %q quoted, space separated.
qargs() {
  local out="" a
  for a in "$@"; do
    out+=" $(printf '%q' "$a")"
  done
  printf '%s' "${out# }"
}

# caps_val KEY: the last value written for KEY to the case's encoder_caps.
caps_val() {
  awk -v k="$1=" 'index($0, k) == 1 { v = substr($0, length(k) + 1) } END { printf "%s", v }' \
    "$LOG_DIR/encoder_caps" 2>/dev/null
}

# launches: the number of gst-launch-1.0 runs in the case so far.
launches() {
  grep -c '^gst-launch-1[.]0 ' "$T_CALLS" || true
}

# dri_nodes: three fake render nodes under $T_TMP/dri, links to the /dev/null device.
dri_nodes() {
  mkdir -p "$T_TMP/dri"
  ln -s /dev/null "$T_TMP/dri/renderD128"
  ln -s /dev/null "$T_TMP/dri/renderD129"
  ln -s /dev/null "$T_TMP/dri/renderD130"
}

amd_vendor_gate() {
  local v
  for v in "" nvidia; do
    t_case "va helpers do nothing unless GS_GPU_VENDOR=amd (vendor '${v}')"
    nv_stubs "vah264enc /dev/null" "vapostproc /dev/null"
    lib_run GS_GPU_VENDOR="$v" GS_RENDER_NODE=/dev/null 'for f in "gs_va_element h264enc" \
  "_gs_va_trial h264 vah264enc 1920x1080" "_gs_va_ok h264 vah264enc" _gs_va_gfx \
  "_gs_va_rdna4_size_ok 1280x720" "_gs_va_scale_ok h264 vah264enc 2560x1440 1920x1080" \
  "_active_encoder_is_va h264" "gs_encoder_status live h264 h264 x264enc videoscale"; do
  $f
  printf "%s=%s\n" "${f%% *}" "$?"
done'
    assert_eq "gs_va_element=1
_gs_va_trial=1
_gs_va_ok=1
_gs_va_gfx=1
_gs_va_rdna4_size_ok=1
_gs_va_scale_ok=1
_active_encoder_is_va=1
gs_encoder_status=0" "$T_STDOUT" "each helper returns at once"
    assert_empty "$T_STDERR" "nothing logged"
    assert_empty "$(grep -E '^(gst-inspect-1[.]0|gst-launch-1[.]0|vainfo)( |$)' "$T_CALLS")" \
      "no probe, trial or vainfo call"
    assert_no_file "$LOG_DIR/encoder_caps" "no encoder_caps"
  done
}

amd_element() {
  t_case "S4-U2 the va element of the second render node"
  amd_stubs
  dri_nodes
  elements "vah264enc $T_TMP/dri/renderD128" "varenderD129h264enc $T_TMP/dri/renderD129"
  amd_run GS_TEST_NODE="$T_TMP/dri/renderD129" 'gs_va_element h264enc'
  assert_rc 0 "renderD129 has an element"
  assert_eq varenderD129h264enc "$T_STDOUT" "the element name, nothing else on stdout"
  assert_eq "vah264enc
varenderD129h264enc" "$(t_calls gst-inspect-1.0)" "va<kind> first, then va<node><kind>"
  assert_eq varenderD129h264enc "$(caps_val element.h264enc)" "element.h264enc"
  assert_eq "amd|$T_TMP/dri/renderD129|0000:c6:00.0" \
    "$(caps_val vendor)|$(caps_val render_node)|$(caps_val pci)" "vendor, render_node and pci"
  amd_run GS_TEST_NODE="$T_TMP/dri/renderD129" 'gs_va_element h264enc'
  assert_eq varenderD129h264enc "$T_STDOUT" "the second call answers"
  assert_eq 2 "$(grep -c '^gst-inspect-1[.]0 ' "$T_CALLS")" "from encoder_caps (S4-U8)"

  t_case "S4-U2 no va element drives the render node"
  amd_stubs
  dri_nodes
  elements "vah264enc $T_TMP/dri/renderD128" "varenderD129h264enc $T_TMP/dri/renderD129"
  amd_run GS_TEST_NODE="$T_TMP/dri/renderD130" 'gs_va_element h264enc'
  assert_rc 1 "renderD130 has no element"
  assert_empty "$T_STDOUT" "nothing on stdout"
  assert_eq none:device-mismatch "$(caps_val element.h264enc)" "device-mismatch"

  t_case "S4-U2 no render node"
  amd_stubs "${VA_ALL[@]}"
  amd_run GS_TEST_NODE= 'gs_va_element h264enc; echo "rc=$?"
GS_RENDER_NODE="$LOG_DIR/gpu_identity" gs_va_element h265enc; echo "rc=$?"'
  assert_eq "rc=1
rc=1" "$T_STDOUT" "an empty node and a regular file both fail"
  assert_eq none:no-render-node "$(caps_val element.h264enc)" "no-render-node for an empty node"
  assert_eq none:no-render-node "$(caps_val element.h265enc)" "no-render-node for a file"
  assert_empty "$(t_calls gst-inspect-1.0)" "no gst-inspect-1.0 call"

  t_case "S4-U2 no va element registered"
  amd_stubs x264enc
  dri_nodes
  amd_run GS_TEST_NODE="$T_TMP/dri/renderD128" 'gs_va_element postproc'
  assert_rc 1 "no element"
  assert_eq none:no-element "$(caps_val element.postproc)" "no-element"
  assert_eq "vapostproc
varenderD128postproc" "$(t_calls gst-inspect-1.0)" "both candidates tried"
}

# u4_want H264 H265: the table u4_table prints when each codec follows its rule: ok (all
# five sizes pass their trial), all:<reason> (all five are refused with no trial) or
# unaligned:<reason> (1920x1080 passes; the four sizes that are not 64-aligned after
# rounding up to 16 are refused with no trial).
u4_want() {
  local codec rule dims
  for codec in h264 h265; do
    rule="$1"
    [ "$codec" = h265 ] && rule="$2"
    for dims in 1920x1080 1280x720 1600x900 2560x1440 720x1280; do
      case "$rule" in
        ok) echo "$codec $dims rc=0 reason=ok trials=1" ;;
        all:*) echo "$codec $dims rc=1 reason=${rule#all:} trials=0" ;;
        unaligned:*)
          if [ "$dims" = 1920x1080 ]; then
            echo "$codec $dims rc=0 reason=ok trials=1"
          else
            echo "$codec $dims rc=1 reason=${rule#unaligned:} trials=0"
          fi
          ;;
      esac
    done
  done
}

# u4_table TOKEN: _gs_va_ok for both codecs at the five sizes, with TOKEN cached as the
# gfx value. One line per cell: codec, size, return status, <codec>_reason and the
# number of trials the cell ran.
u4_table() {
  amd_run "GFX=$1" 'printf "gfx=%s\n" "$GFX" >> "$LOG_DIR/encoder_caps"
for codec in h264 h265; do
  for dims in 1920x1080 1280x720 1600x900 2560x1440 720x1280; do
    before=$(grep -c "^gst-launch-1[.]0 " "$T_CALLS")
    GS_ENC_DIMS=$dims
    rc=0
    _gs_va_ok "$codec" "va${codec}enc" || rc=$?
    after=$(grep -c "^gst-launch-1[.]0 " "$T_CALLS")
    printf "%s %s rc=%s reason=%s trials=%s\n" "$codec" "$dims" "$rc" \
      "$(_gs_caps_get "${codec}_reason")" "$((after - before))"
  done
done'
}

amd_static_rules() {
  local row tok h264 h265 word
  for row in "gfx1201 ok unaligned:rdna4-dpb-size" "- ok unaligned:gfx-unknown-dpb-size" \
    "gfx1151 ok ok" "navi31 ok ok" "polaris10 all:pre-vcn-unsoaked all:pre-vcn-unsoaked" \
    "vega10 all:pre-vcn-unsoaked all:pre-vcn-unsoaked"; do
    read -r tok h264 h265 <<< "$row"
    [ "$tok" = - ] && tok=""
    t_case "S4-U4 static rules with the gfx token '${tok}'"
    amd_stubs "${VA_ALL[@]}"
    u4_table "$tok"
    assert_eq "$(u4_want "$h264" "$h265")" "$T_STDOUT" "ten cells, no trial for a refused cell"
    assert_empty "$(t_calls vainfo)" "the cached token is used"
  done

  t_case "S4-U4 the gfx token from the radeonsi driver string"
  amd_stubs
  echo navi31 > "$T_TMP/gfx"
  amd_run '_gs_va_gfx; echo
_gs_va_gfx'
  assert_eq "navi31
navi31" "$T_STDOUT" "the family token, then the cached one"
  assert_eq "--display drm --device /dev/null" "$(t_calls vainfo)" "one vainfo call on the node"
  assert_eq "navi31|0x1586" "$(caps_val gfx)|$(caps_val device_id)" "gfx and device_id cached"

  for word in "LLVM 15.0.7" ACO; do
    t_case "S4-U4 a compiler word after radeonsi ($word) gives the RADV token"
    amd_stubs
    printf '%s\n' 'name=Radeon 8060S Graphics (RADV GFX1151)' device_id=0x1586 \
      > "$LOG_DIR/gpu_identity"
    t_stub vainfo "echo 'vainfo: Driver version: Mesa Gallium driver 23.2.1 for AMD Radeon Graphics (radeonsi, $word, DRM 3.54, 6.5.0)'"
    amd_run '_gs_va_gfx'
    assert_eq gfx1151 "$T_STDOUT" "the RADV token, lowercased"

    t_case "S4-U4 a compiler word after radeonsi ($word) and no identity give no token"
    amd_stubs
    rm -f "$LOG_DIR/gpu_identity"
    t_stub vainfo "echo 'vainfo: Driver version: Mesa Gallium driver 23.2.1 for AMD Radeon Graphics (radeonsi, $word, DRM 3.54, 6.5.0)'"
    amd_run '_gs_va_gfx; echo "rc=$?"'
    assert_eq "rc=0" "$T_STDOUT" "no token printed, never llvm or aco"
    assert_eq "gfx=" "$(grep '^gfx=' "$LOG_DIR/encoder_caps")" "an empty token is cached"
  done

  t_case "S4-U4 the RADV name alone gives the token"
  amd_stubs
  printf '%s\n' 'name=Radeon 8060S Graphics (RADV GFX1151)' > "$LOG_DIR/gpu_identity"
  t_stub vainfo 'exit 1'
  amd_run '_gs_va_gfx'
  assert_eq gfx1151 "$T_STDOUT" "gfx1151"
}

amd_trials() {
  local rc ms
  t_case "S4-U8 one trial per codec, element and size across subshells"
  amd_stubs "${VA_ALL[@]}"
  amd_run 'a=$(_gs_va_ok h264 vah264enc; echo "rc=$?")
b=$(_gs_va_ok h264 vah264enc; echo "rc=$?")
c=$(GS_ENC_DIMS=2560x1440; _gs_va_ok h264 vah264enc; echo "rc=$?")
d=$(GS_ENC_DIMS=320x240; _gs_va_ok h264 vah264enc; echo "rc=$?")
echo "$a $b $c $d"'
  assert_eq "rc=0 rc=0 rc=0 rc=0" "$T_STDOUT" "every call passes"
  assert_eq 3 "$(launches)" "one trial per size"
  assert_eq "ok|ok|ok" "$(caps_val trial.h264.vah264enc.1920x1080)|$(caps_val trial.h264.vah264enc.2560x1440)|$(caps_val trial.h264.vah264enc.640x480)" \
    "trial keys, 320x240 raised to 640x480"
  assert_eq 1 "$(t_calls vainfo | grep -c .)" "one vainfo call"
  assert_eq vapostproc "$(t_calls gst-inspect-1.0)" "one postproc lookup"
  assert_eq "$(qargs -q videotestsrc num-buffers=1 ! video/x-raw,format=BGRA,width=1920,height=1080,framerate=60/1 \
    ! vapostproc ! 'video/x-raw(memory:VAMemory),format=NV12' ! vah264enc "${VA_TRIAL_PROPS[@]}" \
    target-usage=4 ! h264parse ! fakesink sync=false)" "$(t_calls gst-launch-1.0 | head -n 1)" \
    "the S4-D5 trial command"

  t_case "S4-U8 a failed trial is retried once and cached"
  amd_stubs "${VA_ALL[@]}"
  t_stub gst-launch-1.0 'echo "trial output"; exit 1'
  amd_run '_gs_va_ok h265 vah265enc; echo "rc=$?"
( _gs_va_ok h265 vah265enc; echo "rc=$?" )'
  assert_eq "rc=1
rc=1" "$T_STDOUT" "both calls refuse"
  assert_eq 2 "$(launches)" "two runs, then the cache"
  assert_eq "fail:1|trial-fail" "$(caps_val trial.h265.vah265enc.1920x1080)|$(caps_val h265_reason)" \
    "fail:1 and trial-fail"
  assert_eq 2 "$(grep -c '^trial output$' "$LOG_DIR/encoder_trials.log")" "output in encoder_trials.log"

  t_case "S4-U8 a trial without a postproc element uses NV12 source caps"
  amd_stubs "vah264enc /dev/null"
  amd_run 'GS_ENC_DIMS=1280x720 GS_VA_TARGET_USAGE=2; _gs_va_ok h264 vah264enc'
  assert_rc 0 "passes"
  assert_eq "$(qargs -q videotestsrc num-buffers=1 ! video/x-raw,format=NV12,width=1280,height=720,framerate=60/1 \
    ! vah264enc "${VA_TRIAL_PROPS[@]}" target-usage=2 ! h264parse ! fakesink sync=false)" \
    "$(t_calls gst-launch-1.0)" "NV12 caps, no postproc, the target-usage knob"

  t_case "S4-U13 a trial that ignores SIGTERM ends within 26 s and is not retried"
  amd_stubs "${VA_ALL[@]}"
  t_stub gst-launch-1.0 "trap '' TERM
sleep 60"
  amd_run 'start=$(date +%s%N)
_gs_va_ok h264 vah264enc
rc=$?
echo "$rc $(( ($(date +%s%N) - start) / 1000000 ))"'
  read -r rc ms <<< "$T_STDOUT"
  assert_eq 1 "$rc" "refused"
  assert_eq 1 "$(( ${ms:-99999} < 26000 ))" "returned within 26 s (took ${ms:-?} ms)"
  assert_eq 1 "$(launches)" "no retry after a timeout"
  assert_eq "fail:137|trial-timeout" "$(caps_val trial.h264.vah264enc.1920x1080)|$(caps_val h264_reason)" \
    "fail:137 and trial-timeout"

  t_case "S4-U14 the helpers print only their result while the tools print banners"
  amd_stubs "${VA_ALL[@]}"
  t_stub gst-launch-1.0 'echo "launch banner"; echo "launch warning" >&2'
  amd_run GS_TEST_BANNER=1 'echo "element=[$(gs_va_element h264enc)]"
echo "gfx=[$(_gs_va_gfx)]"
echo "trial=[$(_gs_va_trial h264 vah264enc 1920x1080)]"
echo "ok=[$(_gs_va_ok h265 vah265enc)]"
echo "scale=[$(_gs_va_scale_ok h265 vah265enc 2560x1440 1920x1080)]"'
  assert_eq "element=[vah264enc]
gfx=[gfx1151]
trial=[]
ok=[]
scale=[]" "$T_STDOUT" "results only"
  assert_empty "$T_STDERR" "nothing on stderr"
  assert_eq 3 "$(grep -c '^launch banner$' "$LOG_DIR/encoder_trials.log")" "trial stdout in encoder_trials.log"
  assert_eq 3 "$(grep -c '^launch warning$' "$LOG_DIR/encoder_trials.log")" "trial stderr in encoder_trials.log"

  t_case "S4-U12 the scale trial: two frames scaled by the postproc into the encoder"
  amd_stubs "${VA_ALL[@]}"
  amd_run '_gs_va_scale_ok h265 vah265enc 2560x1440 1920x1080; echo "rc=$?"
_gs_va_scale_ok h265 vah265enc 2560x1440 1920x1080; echo "rc=$?"'
  assert_eq "rc=0
rc=0" "$T_STDOUT" "passes, then cached"
  assert_eq 1 "$(launches)" "one scale trial"
  assert_eq ok "$(caps_val scale.vah265enc.2560x1440.1920x1080)" "the scale key"
  assert_eq "$(qargs -q videotestsrc num-buffers=2 ! video/x-raw,format=BGRA,width=2560,height=1440,framerate=60/1 \
    ! vapostproc ! 'video/x-raw(memory:VAMemory),format=NV12,width=1920,height=1080' \
    ! vah265enc "${VA_TRIAL_PROPS[@]}" target-usage=4 ! h265parse ! fakesink sync=false)" \
    "$(t_calls gst-launch-1.0)" "the scale trial command"

  t_case "S4-U12 a failed scale trial is retried once and cached"
  amd_stubs "${VA_ALL[@]}"
  t_stub gst-launch-1.0 'exit 1'
  amd_run '_gs_va_scale_ok h264 vah264enc 2560x1440 1920x1080; echo "rc=$?"
_gs_va_scale_ok h264 vah264enc 2560x1440 1920x1080; echo "rc=$?"'
  assert_eq "rc=1
rc=1" "$T_STDOUT" "refused twice"
  assert_eq 2 "$(launches)" "two runs, then the cache"
  assert_eq fail:1 "$(caps_val scale.vah264enc.2560x1440.1920x1080)" "fail:1"

  t_case "S4 error 11: an unwritable LOG_DIR never breaks a helper"
  amd_stubs "${VA_ALL[@]}"
  : > "$T_TMP/file"
  amd_run 'LOG_DIR="$T_TMP/file/log"
echo "element=[$(gs_va_element h264enc)]"
_gs_va_ok h264 vah264enc; echo "ok=$?"
_gs_va_ok h264 vah264enc; echo "ok=$?"
gs_encoder_status live h264 h264 vah264enc videoscale'
  assert_eq "element=[vah264enc]
ok=0
ok=0
[enc] ENCODER-CAPS: mode=live requested=h264 actual=h264 encoder=vah264enc device=/dev/null gfx=gfx1151 device_id=? scaler=cpu reason=ok" \
    "$T_STDOUT" "every helper answers, nothing cached"
  assert_empty "$T_STDERR" "no error printed"
  assert_eq 2 "$(launches)" "each call runs its own trial"
}

# caps_line WARN? MODE REQ ACT ENC SCALER REASON: the ENCODER-CAPS line of the AMD node
# (device /dev/null, gfx1151, device id 0x1586), with "WARN: " when the first argument
# is warn.
caps_line() {
  local w=""
  [ "$1" = warn ] && w="WARN: "
  printf '[enc] %sENCODER-CAPS: mode=%s requested=%s actual=%s encoder=%s device=/dev/null gfx=gfx1151 device_id=0x1586 scaler=%s reason=%s' \
    "$w" "$2" "$3" "$4" "$5" "$6" "$7"
}

amd_status() {
  local r
  t_case "S4-U9 a live ENCODER-CAPS line with all nine fields"
  amd_stubs "${VA_ALL[@]}"
  amd_run CONV="$VA_CONV" 'gs_encoder_status live h264 h264 "vah264enc rate-control=vbr bitrate=12000" "$CONV"'
  assert_eq "$(caps_line log live h264 h264 vah264enc vapostproc ok)" "$T_STDOUT" "a plain line on stdout"
  assert_empty "$T_STDERR" "no WARN"
  assert_eq "h264|h264|ok" "$(caps_val requested.live)|$(caps_val actual.live)|$(caps_val reason.live)" \
    "requested.live, actual.live and reason.live"

  for r in no-render-node no-element device-mismatch trial-fail trial-timeout rdna4-dpb-size \
    gfx-unknown-dpb-size pre-vcn-unsoaked forced-x264enc; do
    t_case "S4-U9 reason $r: hevc dropped on live, software on clips"
    amd_stubs "${VA_ALL[@]}"
    printf '%s\n' "h265_reason=$r" "h264_reason=$r" > "$LOG_DIR/encoder_caps"
    amd_run CONV="$VA_CONV" CPU="$CPU_CONV" 'gs_encoder_status live h265 h264 "vah264enc bitrate=12000" "$CONV"
gs_encoder_status clip h264 h264 "x264enc tune=zerolatency" "$CPU"'
    assert_empty "$T_STDOUT" "no plain line"
    assert_eq "$(caps_line warn live h265 h264 vah264enc vapostproc "$r")
$(caps_line warn clip h264 h264 x264enc cpu "$r")" "$T_STDERR" "two WARN lines"
    assert_eq "$r|$r" "$(caps_val reason.live)|$(caps_val reason.clip)" "reason.live and reason.clip"
  done

  t_case "S4-U9 reason va-scale-fail: a VA encoder behind the CPU scaler"
  amd_stubs "${VA_ALL[@]}"
  echo 'scale.vah264enc.2560x1440.1920x1080=fail:1' > "$LOG_DIR/encoder_caps"
  amd_run CS2_DISPLAY_RES=2560x1440 CPU="$CPU_CONV" \
    'gs_encoder_status live h264 h264 "vah264enc bitrate=12000" "$CPU"'
  assert_eq "$(caps_line log live h264 h264 vah264enc cpu va-scale-fail)" "$T_STDOUT" \
    "a plain line with va-scale-fail"
  assert_empty "$T_STDERR" "no WARN"

  t_case "S4-U9 inline lines take the reason from the sixth argument"
  amd_stubs "${VA_ALL[@]}"
  printf '%s\n' h264_reason=trial-fail h265_reason=no-element > "$LOG_DIR/encoder_caps"
  amd_run 'gs_encoder_status inline h264 h264 libx264 "" retry-fail
gs_encoder_status inline h265 h265 hevc_vaapi "" ok
gs_encoder_status inline h265 h264 h264_vaapi "" trial-timeout'
  assert_eq "$(caps_line log inline h265 h265 hevc_vaapi cpu ok)" "$T_STDOUT" "hevc_vaapi: a plain line"
  assert_eq "$(caps_line warn inline h264 h264 libx264 cpu retry-fail)
$(caps_line warn inline h265 h264 h264_vaapi cpu trial-timeout)" "$T_STDERR" \
    "libx264 and a dropped hevc: WARN lines"
  assert_eq "h265|h264|trial-timeout" \
    "$(caps_val requested.inline)|$(caps_val actual.inline)|$(caps_val reason.inline)" "the last inline keys"

  t_case "S4-U9 no identity, no vainfo token and no render node print question marks"
  amd_stubs "${VA_ALL[@]}"
  rm -f "$LOG_DIR/gpu_identity"
  echo h264_reason=no-render-node > "$LOG_DIR/encoder_caps"
  t_stub vainfo 'exit 1'
  amd_run GS_TEST_NODE= 'gs_encoder_status live h264 h264 "x264enc tune=zerolatency" videoscale'
  assert_eq "[enc] WARN: ENCODER-CAPS: mode=live requested=h264 actual=h264 encoder=x264enc device=? gfx=? device_id=? scaler=cpu reason=no-render-node" \
    "$T_STDERR" "question marks for the unknown fields"

  t_case "S4-U9 no arguments under set -u"
  amd_stubs "${VA_ALL[@]}"
  amd_run 'gs_encoder_status; echo "rc=$?"'
  assert_eq "rc=0" "$(printf '%s\n' "$T_STDOUT" | tail -n 1)" "returns 0"
  assert_not_contains "$T_STDERR" "unbound variable" "no unbound variable"
}

# S4-U1: the VA rungs of the encoder ladder (S4-D3), run through _ensure_nvenc_pick as the
# pickers run them, with the probe cache half of S4-U8 and the pick half of S4-U14.
# PICKS defines picks, which resolves both codecs and prints "<h265 pick>|<h264 pick>";
# "$(picks)" stands for a picker subshell, so a second one shows what a later subshell
# finds in the probe cache.
PICKS='picks() {
  _ensure_nvenc_pick h265
  _ensure_nvenc_pick h264
  echo "$GS_NVENC_PICK_H265|$GS_NVENC_PICK"
}
'
HEVC_NONE="[enc]   encoder: no NVENC HEVC encoder available $DASH caller will fall back to h264"

amd_ladder() {
  local v
  t_case "S4-U1 amd picks va:vah265enc and va:vah264enc after the nv rungs (S4-U8, S4-U14)"
  amd_stubs "${VA_ALL[@]}"
  amd_run GS_TEST_BANNER=1 "$PICKS"'echo "$(picks)"
echo "$(picks)"'
  assert_eq "va:vah265enc|va:vah264enc
va:vah265enc|va:vah264enc" "$T_STDOUT" "exactly va:<element>, also from the probe cache"
  assert_eq "[enc]   encoder: vah265enc (GPU, VA-API on /dev/null)
[enc]   encoder: vah264enc (GPU, VA-API on /dev/null)" "$T_STDERR" "one log line per rung"
  assert_eq "nvcudah265enc
nvh265enc
vah265enc
nvcudah264enc
nvh264enc
vah264enc" "$(t_calls gst-inspect-1.0)" "nvcuda, nv, then va; the second subshell probes nothing"
  assert_eq 0 "$(launches)" "no trial in the rungs"
  assert_eq "va:vah265enc|va:vah264enc" "$(caps_val h265)|$(caps_val h264)" "h265= and h264="
  assert_eq "GS_NVENC_PICK_H265=va:vah265enc
GS_NVENC_PICK=va:vah264enc" "$(cat "$T_TMP/gst-probes.env" 2>/dev/null)" \
    "both picks in the probe cache"

  for v in "" nvidia; do
    t_case "S4-U1 no va call with GS_GPU_VENDOR='${v}', also when the force values are va"
    nv_stubs "${VA_ALL[@]}"
    lib_run GS_GPU_VENDOR="$v" GS_RENDER_NODE=/dev/null "$PICKS"'echo "$(picks)"
GS_NVENC_ELEMENT=va GS_NVENC_H265_ELEMENT=va
echo "$(picks)"'
    assert_eq "none|x264enc
none|x264enc" "$T_STDOUT" "today's picks"
    assert_eq "$HEVC_NONE
[enc]   encoder: x264enc (software fallback)
$HEVC_NONE
[enc] WARN: GS_NVENC_ELEMENT=va forced but unavailable
[enc]   encoder: x264enc (software fallback)" "$T_STDERR" \
      "GS_NVENC_ELEMENT=va warns (C2), GS_NVENC_H265_ELEMENT=va stays as quiet as today"
    assert_eq "nvcudah265enc
nvh265enc
nvcudah264enc
nvh264enc" "$(t_calls gst-inspect-1.0)" "the nv rungs only, and only for auto"
    assert_empty "$(grep -E '^(gst-inspect-1[.]0 va|vainfo)' "$T_CALLS")" "no va probe, no vainfo"
    assert_no_file "$LOG_DIR/encoder_caps" "no encoder_caps"
  done

  t_case "S4-U1 GS_NVENC_ELEMENT=va and GS_NVENC_H265_ELEMENT=va on amd skip the nv rungs"
  amd_stubs "${VA_ALL[@]}"
  amd_run GS_NVENC_ELEMENT=va GS_NVENC_H265_ELEMENT=va "$PICKS"'picks'
  assert_eq "va:vah265enc|va:vah264enc" "$T_STDOUT" "both va picks"
  assert_eq "vah265enc
vah264enc" "$(t_calls gst-inspect-1.0)" "no nv probe"
  assert_eq "[enc]   encoder: vah265enc (GPU, VA-API on /dev/null)
[enc]   encoder: vah264enc (GPU, VA-API on /dev/null)" "$T_STDERR" "no warning"

  t_case "S4-U1 va forced on amd without a va encoder warns and falls back, in each subshell"
  amd_stubs x264enc
  amd_run GS_NVENC_ELEMENT=va GS_NVENC_H265_ELEMENT=va "$PICKS"'echo "$(picks)"
echo "$(picks)"'
  assert_eq "none|x264enc
none|x264enc" "$T_STDOUT" "none and x264enc"
  assert_eq "[enc] WARN: GS_NVENC_H265_ELEMENT=va forced but unavailable, falling through
$HEVC_NONE
[enc] WARN: GS_NVENC_ELEMENT=va forced but unavailable
[enc]   encoder: x264enc (software fallback)
[enc] WARN: GS_NVENC_H265_ELEMENT=va forced but unavailable, falling through
$HEVC_NONE
[enc] WARN: GS_NVENC_ELEMENT=va forced but unavailable
[enc]   encoder: x264enc (software fallback)" "$T_STDERR" "both warnings, twice"
  assert_eq "vah265enc
vanullh265enc
vah264enc
vanullh264enc" "$(t_calls gst-inspect-1.0)" "the second subshell answers from encoder_caps"
  assert_eq "h265=none
h265_reason=no-element
h264=x264enc
h264_reason=no-element" "$(grep -E '^h26[45](_reason)?=' "$LOG_DIR/encoder_caps" 2>/dev/null)" \
    "each key written once"

  t_case "S4-U1 GS_NVENC_ELEMENT=x264enc forces software on amd, reason forced-<value>"
  amd_stubs "${VA_ALL[@]}"
  amd_run GS_NVENC_ELEMENT=x264enc GS_NVENC_H265_ELEMENT=nvh265enc "$PICKS"'picks'
  assert_eq "none|x264enc" "$T_STDOUT" "no va pick"
  assert_eq "[enc] WARN: GS_NVENC_H265_ELEMENT=nvh265enc forced but unavailable $DASH \
falling through
$HEVC_NONE
[enc]   encoder: x264enc (software fallback)" "$T_STDERR" "today's lines"
  assert_eq nvh265enc "$(t_calls gst-inspect-1.0)" "the forced nv element only"
  assert_eq "none|forced-nvh265enc|x264enc|forced-x264enc" \
    "$(caps_val h265)|$(caps_val h265_reason)|$(caps_val h264)|$(caps_val h264_reason)" \
    "h265, h265_reason, h264 and h264_reason"

  t_case "S4-U1 an hevc failure yields none while h264 picks va (S4-U14 banners)"
  amd_stubs "vah264enc /dev/null" "vah265enc /dev/dri/renderD999" "vapostproc /dev/null"
  amd_run GS_TEST_BANNER=1 "$PICKS"'picks
h265_available
echo "h265_available=$?"'
  assert_eq "none|va:vah264enc
h265_available=1" "$T_STDOUT" "exactly none and va:vah264enc"
  assert_eq "$HEVC_NONE
[enc]   encoder: vah264enc (GPU, VA-API on /dev/null)" "$T_STDERR" "the closing hevc line"
  assert_eq "none|device-mismatch|va:vah264enc" \
    "$(caps_val h265)|$(caps_val h265_reason)|$(caps_val h264)" "h265, h265_reason and h264"
  assert_eq "GS_NVENC_PICK=va:vah264enc" "$(cat "$T_TMP/gst-probes.env" 2>/dev/null)" \
    "none is never cached"
}
# S4-U3 and S4-U5: the va: arms of the pickers and of h265_available (S4 C4), with the
# picker half of S4-U8 and S4-U14. The S4-D9 live and S4-D11 clip strings at 12000 kbps
# (HEVC at 70% of it) and 60 fps, where stream.sh passes the frame rate as gop and
# clip-capture.sh twice the frame rate, and the x264enc string at gop 60.
VA_LIVE_H264='vah264enc rate-control=vbr target-percentage=95 bitrate=12000 cpb-size=12000 key-int-max=60 b-frames=0 ref-frames=1 target-usage=4'
VA_LIVE_H265='vah265enc rate-control=vbr target-percentage=95 bitrate=8400 cpb-size=8400 key-int-max=60 b-frames=0 ref-frames=1 target-usage=4'
VA_CLIP_H264='vah264enc rate-control=vbr target-percentage=80 bitrate=12000 key-int-max=120 b-frames=0 target-usage=4'
VA_CLIP_H265='vah265enc rate-control=vbr target-percentage=80 bitrate=8400 key-int-max=120 b-frames=0 target-usage=4'
X264_STRING='x264enc tune=zerolatency speed-preset=veryfast bitrate=12000 key-int-max=60'
# A gst-launch-1.0 stub whose runs fail at 1280x720 and pass at every other size.
FAIL_720='case "$*" in *width=1280,height=720*) exit 1 ;; esac
exit 0'

amd_pickers() {
  t_case "S4-U3 the S4-D9 and S4-D11 strings, one trial per codec across subshells (S4-U8, S4-U14)"
  amd_stubs "${VA_ALL[@]}"
  t_stub gst-launch-1.0 'echo "launch banner"'
  amd_run GS_TEST_BANNER=1 'for m in live clip live; do
  if [ "$m" = clip ]; then g=120; else g=60; fi
  a=$(pick_h264_pipeline "$g" 12000 "$m"); ra=$?
  b=$(pick_h265_pipeline "$g" 12000 "$m"); rb=$?
  printf "%s\n%s\n" "$m $ra [$a]" "$m $rb [$b]"
done'
  assert_eq "live 0 [$VA_LIVE_H264]
live 0 [$VA_LIVE_H265]
clip 0 [$VA_CLIP_H264]
clip 0 [$VA_CLIP_H265]
live 0 [$VA_LIVE_H264]
live 0 [$VA_LIVE_H265]" "$T_STDOUT" "exactly the strings, with banners on"
  assert_eq "[enc]   encoder: vah264enc (GPU, VA-API on /dev/null)
[enc]   encoder: vah265enc (GPU, VA-API on /dev/null)" "$T_STDERR" "only the first subshells resolve"
  assert_eq "nvcudah264enc
nvh264enc
vah264enc
vapostproc
nvcudah265enc
nvh265enc
vah265enc" "$(t_calls gst-inspect-1.0)" "later subshells probe nothing"
  assert_eq 2 "$(launches)" "one trial per codec at 1920x1080"
  assert_eq "ok|ok" \
    "$(caps_val trial.h264.vah264enc.1920x1080)|$(caps_val trial.h265.vah265enc.1920x1080)" \
    "the trial keys"
  assert_eq 1 "$(t_calls vainfo | grep -c .)" "one vainfo call"
  assert_eq 2 "$(grep -c '^launch banner$' "$LOG_DIR/encoder_trials.log")" \
    "the trial banners in encoder_trials.log"

  t_case "S4-U3 the knobs GS_VA_RATE_CONTROL (live only), GS_VA_TARGET_USAGE and GS_VA_H265_PCT"
  amd_stubs "${VA_ALL[@]}"
  amd_run GS_VA_RATE_CONTROL=cbr GS_VA_TARGET_USAGE=2 GS_VA_H265_PCT=50 'for m in live clip; do
  pick_h264_pipeline 120 20000 "$m"; echo
  pick_h265_pipeline 120 20000 "$m"; echo
done'
  assert_eq "vah264enc rate-control=cbr target-percentage=95 bitrate=20000 cpb-size=20000 key-int-max=120 b-frames=0 ref-frames=1 target-usage=2
vah265enc rate-control=cbr target-percentage=95 bitrate=10000 cpb-size=10000 key-int-max=120 b-frames=0 ref-frames=1 target-usage=2
vah264enc rate-control=vbr target-percentage=80 bitrate=20000 key-int-max=120 b-frames=0 target-usage=2
vah265enc rate-control=vbr target-percentage=80 bitrate=10000 key-int-max=120 b-frames=0 target-usage=2" \
    "$T_STDOUT" "the knob values in the strings"

  t_case "S4-U3 the string starts with the element of the pick"
  amd_stubs "${VA_ALL[@]}"
  amd_run GS_NVENC_PICK=va:varenderD129h264enc GS_NVENC_PICK_H265=va:varenderD129h265enc \
    'pick_h264_pipeline 120 12000 clip; echo
pick_h265_pipeline 60 12000 live'
  assert_eq "varenderD129h264enc ${VA_CLIP_H264#* }
varenderD129h265enc ${VA_LIVE_H265#* }" "$T_STDOUT" "the element of each pick"
  assert_eq vapostproc "$(t_calls gst-inspect-1.0)" "no resolver ran; the trials look up the postproc"

  t_case "S4-U5 a cached va:vah265enc is checked again at each output size"
  amd_stubs "${VA_ALL[@]}"
  t_stub gst-launch-1.0 "$FAIL_720"
  echo GS_NVENC_PICK_H265=va:vah265enc > "$T_TMP/gst-probes.env"
  amd_run 'for GS_ENC_DIMS in 1920x1080 1280x720 1920x1080; do
  enc=$(pick_h265_pipeline 60 12000 live); rc=$?
  h265_available; echo "$GS_ENC_DIMS rc=$rc available=$? [$enc]"
done'
  assert_eq "1920x1080 rc=0 available=0 [$VA_LIVE_H265]
1280x720 rc=1 available=1 []
1920x1080 rc=0 available=0 [$VA_LIVE_H265]" "$T_STDOUT" "VA at 1920x1080, not at 1280x720"
  assert_empty "$T_STDERR" "the picker returns 1 quietly; the caller warns"
  assert_eq 3 "$(launches)" "one trial per size, the failed one retried once"
  assert_eq vapostproc "$(t_calls gst-inspect-1.0)" "the cached pick is not resolved again"
  assert_eq "h265_reason=ok
h265_reason=trial-fail
h265_reason=ok" "$(grep '^h265_reason=' "$LOG_DIR/encoder_caps")" "h265_reason follows the size"

  t_case "S4-U5 the caller falls back to h264 at 1280x720; ENCODER-CAPS shows trial-fail there"
  amd_stubs "${VA_ALL[@]}"
  t_stub gst-launch-1.0 'case "$*" in *width=1280,height=720*vah265enc*) exit 1 ;; esac
exit 0'
  amd_run CONV="$CPU_CONV" 'for GS_ENC_DIMS in 1280x720 1920x1080; do
  act=h265
  enc=$(pick_h265_pipeline 60 12000 live) || { act=h264; enc=$(pick_h264_pipeline 60 12000 live); }
  gs_encoder_status live h265 "$act" "$enc" "$CONV"
done'
  assert_eq "$(caps_line log live h265 h265 vah265enc cpu ok)" "$T_STDOUT" \
    "HEVC on VA at 1920x1080"
  assert_eq "[enc]   encoder: vah265enc (GPU, VA-API on /dev/null)
[enc]   encoder: vah264enc (GPU, VA-API on /dev/null)
$(caps_line warn live h265 h264 vah264enc cpu trial-fail)" "$T_STDERR" \
    "VA H.264 at 1280x720, with a WARN line"
  assert_eq 4 "$(launches)" "hevc at 1280x720 twice, h264 at 1280x720, hevc at 1920x1080"

  t_case "S4-U5 a va h264 pick refused at the output size warns and gives x264enc"
  amd_stubs "${VA_ALL[@]}"
  t_stub gst-launch-1.0 "$FAIL_720"
  amd_run 'for GS_ENC_DIMS in 1280x720 1920x1080; do
  echo "$GS_ENC_DIMS [$(pick_h264_pipeline 60 12000 live)]"
done'
  assert_eq "1280x720 [$X264_STRING]
1920x1080 [$VA_LIVE_H264]" "$T_STDOUT" "today's x264enc string at 1280x720 only"
  assert_eq "[enc]   encoder: vah264enc (GPU, VA-API on /dev/null)
[enc] WARN: VA H.264 encoder not usable at 1280x720 (reason=trial-fail), using x264enc" \
    "$T_STDERR" "the C4 warning"
  assert_eq "va:vah264enc|ok" "$(caps_val h264)|$(caps_val h264_reason)" "the pick stays va:"

  t_case "S4-U5 a pre-VCN token refuses both va picks with no trial"
  amd_stubs "${VA_ALL[@]}"
  echo polaris10 > "$T_TMP/gfx"
  amd_run 'echo "[$(pick_h264_pipeline 60 12000 clip)]"
pick_h265_pipeline 60 12000 clip; echo "h265 rc=$?"
h265_available; echo "available=$?"'
  assert_eq "[$X264_STRING]
h265 rc=1
available=1" "$T_STDOUT" "x264enc for H.264, no HEVC"
  assert_eq "[enc]   encoder: vah264enc (GPU, VA-API on /dev/null)
[enc] WARN: VA H.264 encoder not usable at 1920x1080 (reason=pre-vcn-unsoaked), using x264enc
[enc]   encoder: vah265enc (GPU, VA-API on /dev/null)" "$T_STDERR" "one warning, for H.264"
  assert_eq 0 "$(launches)" "no trial"

  t_case "S4-U5 an RDNA4 token at 1280x720 refuses HEVC with no trial, not H.264"
  amd_stubs "${VA_ALL[@]}"
  echo gfx1201 > "$T_TMP/gfx"
  amd_run GS_ENC_DIMS=1280x720 'h265_available; echo "available=$?"
echo "[$(pick_h264_pipeline 60 12000 live)]"'
  assert_eq "available=1
[$VA_LIVE_H264]" "$T_STDOUT" "no HEVC, VA H.264"
  assert_eq "rdna4-dpb-size|ok" "$(caps_val h265_reason)|$(caps_val h264_reason)" "both reasons"
  assert_eq 1 "$(launches)" "the H.264 trial only"
}
# S4-U3 (the S4-D8 fragment), S4-U12 and the scaler half of S4-U5: the VA branch of
# pick_scale_convert (S4 C5), with the pick level of S4-U14. VA_CONV is the S4-D8
# fragment at 1920x1080 and 60 fps, CPU_CONV its fallback (videorate plus today's CPU
# fragment); CPU_1080 and CPU_720 are today's CPU fragment (baseline L475), which the
# NVIDIA and non-VA paths still print.
VA_CONV_1440='videorate ! video/x-raw,framerate=60/1 ! vapostproc ! video/x-raw(memory:VAMemory),format=NV12,width=2560,height=1440,framerate=60/1'
CPU_1080="${CPU_CONV#videorate ! }"
CPU_720='videoscale ! video/x-raw,width=1280,height=720,framerate=60/1 ! videoconvert ! video/x-raw,format=NV12'
SCALER_VA='[enc]   scaler: vapostproc (VA scale+convert)'
SCALER_CPU='[enc]   scaler: CPU videoscale+videoconvert'

amd_scaler() {
  t_case "S4-U3 the S4-D8 fragment for h264, hevc and h265 (S4-U14)"
  amd_stubs "${VA_ALL[@]}"
  t_stub gst-launch-1.0 'echo "launch banner"'
  amd_run GS_TEST_BANNER=1 'for c in h264 hevc h265; do
  f=$(pick_scale_convert 1920 1080 60 "$c")
  echo "$c $? [$f]"
done'
  assert_eq "h264 0 [$VA_CONV]
hevc 0 [$VA_CONV]
h265 0 [$VA_CONV]" "$T_STDOUT" "exactly the fragment, with banners on"
  assert_eq "$SCALER_VA
$SCALER_VA
$SCALER_VA" "$T_STDERR" "the VA log line; the resolvers run quiet"
  assert_eq "nvcudah264enc
nvh264enc
vah264enc
vapostproc
nvcudah265enc
nvh265enc
vah265enc" "$(t_calls gst-inspect-1.0)" "hevc and h265 share one pick"
  assert_eq 2 "$(launches)" "one trial per codec, no scale trial at equal sizes"
  assert_eq 2 "$(grep -c '^launch banner$' "$LOG_DIR/encoder_trials.log")" \
    "the trial banners in encoder_trials.log"
  assert_eq scaler=vapostproc "$(grep '^scaler=' "$LOG_DIR/encoder_caps")" "scaler written once"

  t_case "S4-U3 the fragment names the postproc of the second render node"
  amd_stubs
  dri_nodes
  elements "vah264enc $T_TMP/dri/renderD128" "vapostproc $T_TMP/dri/renderD128" \
    "varenderD129h264enc $T_TMP/dri/renderD129" "varenderD129postproc $T_TMP/dri/renderD129"
  amd_run GS_TEST_NODE="$T_TMP/dri/renderD129" 'pick_scale_convert 1920 1080 60 h264'
  assert_eq "${VA_CONV/vapostproc/varenderD129postproc}" "$T_STDOUT" "varenderD129postproc"
  assert_eq "varenderD129postproc|vapostproc" "$(caps_val element.postproc)|$(caps_val scaler)" \
    "element.postproc and scaler"

  t_case "S4-U12 a 2560x1440 capture scaled to 1920x1080 runs one scale trial"
  amd_stubs "${VA_ALL[@]}"
  amd_run CS2_DISPLAY_RES=2560x1440 'a=$(pick_scale_convert 1920 1080 60 hevc)
b=$(pick_scale_convert 1920 1080 60 hevc)
printf "%s\n%s\n" "[$a]" "[$b]"'
  assert_eq "[$VA_CONV]
[$VA_CONV]" "$T_STDOUT" "the postproc scales"
  assert_eq 2 "$(launches)" "the one-frame trial, then one scale trial"
  assert_eq ok "$(caps_val scale.vah265enc.2560x1440.1920x1080)" "the scale key"
  assert_eq "$(qargs -q videotestsrc num-buffers=2 ! video/x-raw,format=BGRA,width=2560,height=1440,framerate=60/1 \
    ! vapostproc ! 'video/x-raw(memory:VAMemory),format=NV12,width=1920,height=1080' \
    ! vah265enc "${VA_TRIAL_PROPS[@]}" target-usage=4 ! h265parse ! fakesink sync=false)" \
    "$(t_calls gst-launch-1.0 | tail -n 1)" "the scale trial of the HEVC element, with h265parse"

  t_case "S4-U12 a failed scale trial gives the CPU fragment behind videorate; the encoder stays VA"
  amd_stubs "${VA_ALL[@]}"
  t_stub gst-launch-1.0 'case "$*" in *num-buffers=2*) exit 1 ;; esac
exit 0'
  amd_run CS2_DISPLAY_RES=2560x1440 'enc=$(pick_h264_pipeline 60 12000 live)
conv=$(pick_scale_convert 1920 1080 60 h264)
again=$(pick_scale_convert 1920 1080 60 h264)
printf "%s\n%s\n%s\n" "[$enc]" "[$conv]" "[$again]"
gs_encoder_status live h264 h264 "$enc" "$conv"'
  assert_eq "[$VA_LIVE_H264]
[$CPU_CONV]
[$CPU_CONV]
$(caps_line log live h264 h264 vah264enc cpu va-scale-fail)" "$T_STDOUT" \
    "a VA encoder behind the CPU fragment, reason va-scale-fail"
  assert_eq "[enc]   encoder: vah264enc (GPU, VA-API on /dev/null)
$SCALER_CPU
$SCALER_CPU" "$T_STDERR" "today's CPU log line"
  assert_eq 3 "$(launches)" "the one-frame trial, the scale trial and its retry, then the cache"
  assert_eq "fail:1|cpu" "$(caps_val scale.vah264enc.2560x1440.1920x1080)|$(caps_val scaler)" \
    "the scale key and scaler=cpu"

  t_case "S4-U12 equal capture and output sizes run no scale trial"
  amd_stubs "${VA_ALL[@]}"
  amd_run CS2_DISPLAY_RES=2560x1440 GS_ENC_DIMS=2560x1440 'pick_scale_convert 2560 1440 60 h264'
  assert_eq "$VA_CONV_1440" "$T_STDOUT" "the VA fragment at 2560x1440"
  assert_eq 1 "$(launches)" "the one-frame trial only"
  assert_eq "ok|0" \
    "$(caps_val trial.h264.vah264enc.2560x1440)|$(grep -c '^scale[.]' "$LOG_DIR/encoder_caps")" \
    "the trial at the output size, no scale key"

  t_case "S4-D8 GS_GPU_SCALE=0, off, false and no give the CPU fragment behind videorate"
  amd_stubs "${VA_ALL[@]}"
  amd_run 'for GS_GPU_SCALE in 0 off false no auto; do
  echo "$GS_GPU_SCALE [$(pick_scale_convert 1920 1080 60 h264)]"
done'
  assert_eq "0 [$CPU_CONV]
off [$CPU_CONV]
false [$CPU_CONV]
no [$CPU_CONV]
auto [$VA_CONV]" "$T_STDOUT" "the VA fragment for auto only"
  assert_eq "$SCALER_CPU
$SCALER_CPU
$SCALER_CPU
$SCALER_CPU
$SCALER_VA" "$T_STDERR" "today's CPU log line, then the VA one"
  assert_eq 1 "$(launches)" "the encoder stays VA: one trial"
  assert_eq "scaler=cpu
scaler=vapostproc" "$(grep '^scaler=' "$LOG_DIR/encoder_caps")" "scaler written when it changes"

  t_case "S4-D8 no VA postproc drives the render node: the CPU fragment behind videorate"
  amd_stubs "vah264enc /dev/null" "vah265enc /dev/null"
  amd_run CS2_DISPLAY_RES=2560x1440 'pick_scale_convert 1920 1080 60 h264'
  assert_eq "$CPU_CONV" "$T_STDOUT" "the CPU fragment behind videorate"
  assert_eq "$SCALER_CPU" "$T_STDERR" "today's CPU log line"
  assert_eq 1 "$(launches)" "the one-frame trial, no scale trial"
  assert_eq "none:no-element|cpu" "$(caps_val element.postproc)|$(caps_val scaler)" \
    "element.postproc and scaler"

  t_case "S4-U5 the scaler follows a cached va:vah265enc at each output size"
  amd_stubs "${VA_ALL[@]}"
  t_stub gst-launch-1.0 "$FAIL_720"
  echo GS_NVENC_PICK_H265=va:vah265enc > "$T_TMP/gst-probes.env"
  amd_run 'for GS_ENC_DIMS in 1920x1080 1280x720 1920x1080; do
  echo "$GS_ENC_DIMS [$(pick_scale_convert "${GS_ENC_DIMS%x*}" "${GS_ENC_DIMS#*x}" 60 h265)]"
done'
  assert_eq "1920x1080 [$VA_CONV]
1280x720 [$CPU_720]
1920x1080 [$VA_CONV]" "$T_STDOUT" "VA at 1920x1080, today's CPU fragment at 1280x720"
  assert_eq "$SCALER_VA
$SCALER_CPU
$SCALER_VA" "$T_STDERR" "the log line of each branch"
  assert_eq 3 "$(launches)" "one trial per size, the failed one retried once"
  assert_eq vapostproc "$(t_calls gst-inspect-1.0)" "the cached pick is not resolved again"

  t_case "S4-U5 the live flow: x264enc and the CPU scaler at 1280x720, HEVC and vapostproc at 1920x1080"
  amd_stubs "${VA_ALL[@]}"
  t_stub gst-launch-1.0 "$FAIL_720"
  amd_run 'for GS_ENC_DIMS in 1280x720 1920x1080; do
  act=h265
  enc=$(pick_h265_pipeline 60 12000 live) || { act=h264; enc=$(pick_h264_pipeline 60 12000 live); }
  conv=$(pick_scale_convert "${GS_ENC_DIMS%x*}" "${GS_ENC_DIMS#*x}" 60 "$act")
  gs_encoder_status live h265 "$act" "$enc" "$conv"
done'
  assert_eq "$(caps_line log live h265 h265 vah265enc vapostproc ok)" "$T_STDOUT" \
    "a plain line at 1920x1080"
  assert_eq "[enc]   encoder: vah265enc (GPU, VA-API on /dev/null)
[enc]   encoder: vah264enc (GPU, VA-API on /dev/null)
[enc] WARN: VA H.264 encoder not usable at 1280x720 (reason=trial-fail), using x264enc
$SCALER_CPU
$(caps_line warn live h265 h264 x264enc cpu trial-fail)
$SCALER_VA" "$T_STDERR" "a WARN line with reason trial-fail at 1280x720"
  assert_eq 5 "$(launches)" "both codecs fail at 1280x720 (each retried once), HEVC passes at 1920x1080"

  t_case "nvidia: a va: pick set by hand gets today's CPU fragment with no probe"
  nv_stubs "vah264enc /dev/null" "vapostproc /dev/null"
  lib_run GS_RENDER_NODE=/dev/null GS_NVENC_PICK=va:vah264enc 'pick_scale_convert 1920 1080 60 h264'
  assert_eq "$CPU_1080" "$T_STDOUT" "today's CPU fragment, no videorate"
  assert_eq "$SCALER_CPU" "$T_STDERR" "today's log line"
  assert_empty "$(grep -E '^(gst-inspect-1[.]0|gst-launch-1[.]0|vainfo)( |$)' "$T_CALLS")" \
    "no probe, trial or vainfo call"
  assert_no_file "$LOG_DIR/encoder_caps" "no encoder_caps"
}
# S4-U6: the EFC guard, the va*enc* arm of _assert_cuda_chain (S4 C6, S4 error handling
# [10]), and the leaky placement of S4-D10: in a VA chain nothing with leaky= follows
# videorate. EFC_AFTER puts a queue after the postproc's capsfilter, EFC_BETWEEN one
# between the postproc and its capsfilter.
EFC_AFTER="$VA_CONV ! queue"
EFC_BETWEEN='videorate ! video/x-raw,framerate=60/1 ! vapostproc ! queue ! video/x-raw(memory:VAMemory),format=NV12,width=1920,height=1080,framerate=60/1'
EFC_WARN='[enc] WARN: BUG: an element sits between vapostproc and the VA encoder, which breaks EFC'

# chain_tails FILE: the rest of each gst chain in FILE from $convert, $outchain,
# "compositor name=" or videorate on. Comment lines are dropped and backslash-newline
# continuations joined; a tail ends at the named pad (mux., comp.sink_0) that closes
# its chain, or at the end of the line.
chain_tails() {
  awk '
    /^[ \t]*#/ { next }
    { line = held $0; held = "" }
    /\\$/ { held = substr(line, 1, length(line) - 1); next }
    {
      while (match(line, /[$]convert|[$]outchain|compositor name=|videorate/)) {
        line = substr(line, RSTART + RLENGTH)
        n = split(line, w, /[ \t]+/)
        tail = ""
        for (i = 1; i <= n; i++) {
          tail = tail " " w[i]
          if (w[i] ~ /^[A-Za-z_][A-Za-z0-9_]*[.][A-Za-z0-9_]*"?$/) break
        }
        print tail
      }
    }' "$1"
}

amd_guard() {
  t_case "S4-U6 the VA convert and each VA encoder pass _assert_cuda_chain silently"
  amd_stubs "${VA_ALL[@]}"
  amd_run 'for m in live clip; do
  if [ "$m" = clip ]; then g=120; else g=60; fi
  for c in h264 h265; do
    enc=$(pick_${c}_pipeline "$g" 12000 "$m")
    conv=$(pick_scale_convert 1920 1080 60 "$c")
    _assert_cuda_chain "$conv" "$enc" 2>&1
    echo "$m $c ${enc%% *} rc=$? [$conv]"
  done
done'
  assert_eq "live h264 vah264enc rc=0 [$VA_CONV]
live h265 vah265enc rc=0 [$VA_CONV]
clip h264 vah264enc rc=0 [$VA_CONV]
clip h265 vah265enc rc=0 [$VA_CONV]" "$T_STDOUT" "no BUG line, status 0"
  assert_not_contains "$T_STDERR" "WARN" "no warning from the pickers either"

  t_case "S4-U6 an element after the vapostproc caps, or before them, warns once per call"
  amd_stubs
  amd_run C1="$EFC_AFTER" E1="$VA_LIVE_H264" C2="$EFC_BETWEEN" E2="$VA_CLIP_H265" \
    '_assert_cuda_chain "$C1" "$E1"; echo "rc=$?"
_assert_cuda_chain "$C2" "$E2"; echo "rc=$?"'
  assert_eq "rc=0
rc=0" "$T_STDOUT" "warn only: status 0"
  assert_eq "$EFC_WARN (convert=$EFC_AFTER)
$EFC_WARN (convert=$EFC_BETWEEN)" "$T_STDERR" "the BUG warning with the convert"
  assert_empty "$(grep -E '^(gst-inspect-1[.]0|gst-launch-1[.]0|vainfo)( |$)' "$T_CALLS")" \
    "the guard probes nothing"

  t_case "S4-U6 the va arm checks only a VA encoder after vapostproc, from the last vapostproc on"
  amd_stubs
  amd_run C1="$EFC_AFTER" C2="$CPU_CONV ! queue" C3="vapostproc ! queue ! $VA_CONV" \
    E1="$VA_LIVE_H264" E2="$X264_STRING" \
    '_assert_cuda_chain "$C1" "$E2"
_assert_cuda_chain "$C1" "nvh264enc preset=low-latency-hq"
_assert_cuda_chain "$C2" "$E1"
_assert_cuda_chain "$C3" "$E1"
echo "rc=$?"'
  assert_eq rc=0 "$T_STDOUT" "status 0"
  assert_empty "$T_STDERR" "x264enc, nvh264enc, a CPU convert and a clean last vapostproc: no warning"

  local v
  for v in "" nvidia; do
    t_case "nvidia: the va arm of _assert_cuda_chain stays silent (vendor '${v}')"
    nv_stubs
    lib_run GS_GPU_VENDOR="$v" C1="$EFC_AFTER" E1="$VA_LIVE_H264" \
      '_assert_cuda_chain "$C1" "$E1"; echo "rc=$?"'
    assert_eq rc=0 "$T_STDOUT" "status 0"
    assert_empty "$T_STDERR" "no warning"
  done

  t_case "S4-U6 the VA fragments start with videorate; no leaky= in them or in the VA encoders"
  amd_stubs "${VA_ALL[@]}"
  amd_run 'for c in h264 h265; do
  pick_scale_convert 1920 1080 60 "$c"; echo
  GS_GPU_SCALE=0 pick_scale_convert 1920 1080 60 "$c"; echo
done
for m in live clip; do
  if [ "$m" = clip ]; then g=120; else g=60; fi
  pick_h264_pipeline "$g" 12000 "$m"; echo
  pick_h265_pipeline "$g" 12000 "$m"; echo
done'
  assert_eq "$VA_CONV
$CPU_CONV
$VA_CONV
$CPU_CONV
$VA_LIVE_H264
$VA_LIVE_H265
$VA_CLIP_H264
$VA_CLIP_H265" "$T_STDOUT" "the fragments and the encoder strings"
  assert_not_contains "$T_STDOUT" "leaky=" "no leaky= in a fragment or an encoder string"

  t_case "S4-U6 the live and clip chains: no leaky= after videorate or the convert"
  local f tails
  for f in stream.sh clip-capture.sh; do
    tails="$(chain_tails "$GS_REPO/src/lib/$f")"
    assert_contains "$tails" ' ! $enc ' "$f: the scan follows the convert to the encoder"
    assert_not_contains "$tails" "leaky=" "$f: nothing leaky follows videorate or the convert"
  done
  assert_contains "$(grep -v '^[[:space:]]*#' "$GS_REPO/src/lib/stream.sh")" "leaky=downstream" \
    "stream.sh keeps its leaky queues on the HUD and audio legs and before the ximagesrc convert"
}
amd_vendor_gate
amd_element
amd_static_rules
amd_trials
amd_status
amd_ladder
amd_pickers
amd_scaler
amd_guard
# S4-U9, live site (part 11): start_capture on a VA-API node logs exactly one
# ENCODER-CAPS line, with the requested and the actual codec, each named h264 or h265
# (S4 interface [5]). S4 C11: the composite pins BGRA after the compositor only when the
# convert uses vapostproc.
es_amd_case "S4-U9 live site: VA-API h264, one ENCODER-CAPS line, BGRA pin"
es_live "${ES_AMD[@]}"
assert_contains "$T_STDOUT" "rc=0" "start_capture returns 0"
assert_eq 1 "$(es_caps_lines live | grep -c .)" "exactly one ENCODER-CAPS line"
assert_match '^\[game-streamer\] ENCODER-CAPS: mode=live requested=h264 actual=h264 encoder=vah264enc device=/dev/null gfx=gfx1151 device_id=[^ ]+ scaler=vapostproc reason=ok$' \
  "$(es_caps_lines live)" "requested and actual h264, logged, not a WARN"
assert_contains "$(es_pipelines)" \
  "vkcapture-consumer compositor name=comp background=black ! video/x-raw,format=BGRA ! queue max-size-buffers=8 max-size-bytes=0 max-size-time=0 ! videorate ! " \
  "BGRA pin between the compositor and its queue, then the VA convert"

es_amd_case "S4-U9 live site: VA-API h264 without vapostproc, CPU scaler, no BGRA pin"
es_live "${ES_AMD[@]}" "T_GST_ELEMENTS=vah264enc vah265enc"
assert_match '^\[game-streamer\] ENCODER-CAPS: mode=live requested=h264 actual=h264 encoder=vah264enc device=/dev/null gfx=gfx1151 device_id=[^ ]+ scaler=cpu reason=ok$' \
  "$(es_caps_lines live)" "scaler=cpu"
assert_contains "$(es_pipelines)" \
  "vkcapture-consumer compositor name=comp background=black ! queue max-size-buffers=8 " \
  "no BGRA pin without vapostproc"

es_amd_case "S4-U9 live site: h265 refused at 1280x720 on gfx1201, VA-API fallback text" gfx1201
es_live "${ES_AMD[@]}" LIVE_VIDEO_CODEC=h265 LIVE_OUTPUT_DIMS=1280x720
assert_contains "$T_STDERR" \
  "[game-streamer] WARN: LIVE_VIDEO_CODEC=h265 but no VA-API HEVC encoder is usable at 1280x720, falling back to h264 (see ENCODER-CAPS)" \
  "the AMD fallback text names the output size"
assert_not_contains "$T_STDERR" "NVENC" "no NVENC wording on AMD"
assert_contains "$T_STDOUT" "  codec: h264" "h264 after the refusal"
assert_eq 1 "$(es_caps_lines live | grep -c .)" "exactly one ENCODER-CAPS line"
assert_match '^\[game-streamer\] WARN: ENCODER-CAPS: mode=live requested=h265 actual=h264 encoder=vah264enc device=/dev/null gfx=gfx1201 device_id=[^ ]+ scaler=vapostproc reason=rdna4-dpb-size$' \
  "$(es_caps_lines live)" "a WARN line with the refusal reason"

es_amd_case "S4-U9 live site: LIVE_VIDEO_CODEC=hevc is named h265"
es_live "${ES_AMD[@]}" LIVE_VIDEO_CODEC=hevc
assert_contains "$T_STDOUT" "  codec: hevc" "start_capture's own line keeps the hevc spelling"
assert_match '^\[game-streamer\] ENCODER-CAPS: mode=live requested=h265 actual=h265 encoder=vah265enc device=/dev/null gfx=gfx1151 device_id=[^ ]+ scaler=vapostproc reason=ok$' \
  "$(es_caps_lines live)" "requested and actual h265, logged, not a WARN"

es_amd_case "S4-U9 live site: an unrecognized LIVE_VIDEO_CODEC is named h264"
es_live "${ES_AMD[@]}" LIVE_VIDEO_CODEC=av1
assert_match '^\[game-streamer\] ENCODER-CAPS: mode=live requested=h264 actual=h264 encoder=vah264enc device=/dev/null gfx=gfx1151 device_id=[^ ]+ scaler=vapostproc reason=ok$' \
  "$(es_caps_lines live)" "requested h264, the codec upstream uses, logged, not a WARN"

# S4-U15: the VA verdicts depend on the size, so a refusal at one size never blocks
# another. First the helpers alone, then restart_capture from a caller that holds a global
# GS_ENC_DIMS the way inline-clip-render.sh does.
es_amd_case "S4-U15: h265 refused at 1280x720 on gfx1201, then picked at 1920x1080 in a child shell" gfx1201
# shellcheck disable=SC2016  # the script expands in the es_sh shell
es_sh stream.sh "${ES_AMD[@]}" -- 'GS_ENC_DIMS=1280x720
if h265_available; then echo "1280x720: available"; else echo "1280x720: refused, $(_gs_caps_get h265_reason)"; fi
if out=$(GS_ENC_DIMS=1920x1080; pick_h265_pipeline 60 8000 live); then echo "1920x1080: ${out%% *}"; else echo "1920x1080: none"; fi'
assert_eq $'1280x720: refused, rdna4-dpb-size\n1920x1080: vah265enc' "$T_STDOUT" "the refusal does not stick"

es_amd_case "S4-U15: restart_capture under a global GS_ENC_DIMS=1280x720 encodes h265 at the live size" gfx1201
printf '%s\n' a1b2c3d4e5f6 60 8000 true 0 > "$LOG_DIR/capture-a1b2c3d4e5f6.args"
# shellcheck disable=SC2016  # the script expands in the es_sh shell
es_sh stream.sh "${ES_AMD[@]}" LIVE_VIDEO_CODEC=h265 -- 'GS_ENC_DIMS=1280x720
restart_capture a1b2c3d4e5f6
echo "rc=$? GS_ENC_DIMS=$GS_ENC_DIMS"'
assert_contains "$T_STDOUT" "  codec: h265" "h265, judged at 1920x1080"
assert_contains "$T_STDOUT" "rc=0 GS_ENC_DIMS=1280x720" "the caller's global is unchanged"
assert_contains "$(es_pipelines)" " ! vah265enc " "the VA HEVC encoder runs"
assert_contains "$(cat "$LOG_DIR/encoder_caps")" "trial.h265.vah265enc.1920x1080=ok" "the trial ran at the live size"
assert_not_contains "$(cat "$LOG_DIR/encoder_caps")" "h265_reason=rdna4-dpb-size" "no refusal at the caller's size"

# S4-U9, clip site (part 11): each clip capture start on a VA-API node logs exactly one
# ENCODER-CAPS line, with the requested and the actual codec, each named h264 or h265.
# S4 C15: the AMD HEVC fallback text names the output size on the vkcapture and the
# ximagesrc paths. S4 C16: no zero copy on AMD. S4 C17: the AMD spawn-failure text drops
# the NVIDIA modeset hint.
es_amd_case "S4-U9 clip site: vkcapture, VA-API h264, one ENCODER-CAPS line"
es_clip "${ES_AMD[@]}"
assert_contains "$T_STDOUT" "rc=0 ready=$T_TMP/clip/seg-001.mp4.ready" "the vkcapture path started"
assert_eq 1 "$(es_caps_lines clip | grep -c .)" "exactly one ENCODER-CAPS line"
assert_match '^\[game-streamer\] ENCODER-CAPS: mode=clip requested=h264 actual=h264 encoder=vah264enc device=/dev/null gfx=gfx1151 device_id=[^ ]+ scaler=vapostproc reason=ok$' \
  "$(es_caps_lines clip)" "requested and actual h264, logged, not a WARN"
assert_match ' ! vapostproc ! [^!]+ ! vah264enc [^!]+ ! h264parse config-interval=1 ! queue ! mux\. pulsesrc ' \
  "$(es_pipelines)" "the VA scaler and encoder feed the existing parser and the audio mux"

es_amd_case "S4-U9 clip site: vkcapture, h265 refused at 1280x720 on gfx1201, VA-API fallback text" gfx1201
es_clip "${ES_AMD[@]}" CLIP_VIDEO_CODEC=h265 CLIP_OUTPUT_DIMS=1280x720
assert_contains "$T_STDERR" \
  "[game-streamer] WARN: CLIP_VIDEO_CODEC=h265 but no VA-API HEVC encoder is usable at 1280x720, falling back to h264 (see ENCODER-CAPS)" \
  "the AMD fallback text names the output size"
assert_not_contains "$T_STDERR" "NVENC" "no NVENC wording on AMD"
assert_contains "$T_STDOUT" "(vkcapture/present-hook -> 1280x720@60fps, 16000kbps, audio=1, codec=h264)" \
  "h264 after the refusal"
assert_eq 1 "$(es_caps_lines clip | grep -c .)" "exactly one ENCODER-CAPS line"
assert_match '^\[game-streamer\] WARN: ENCODER-CAPS: mode=clip requested=h265 actual=h264 encoder=vah264enc device=/dev/null gfx=gfx1201 device_id=[^ ]+ scaler=vapostproc reason=rdna4-dpb-size$' \
  "$(es_caps_lines clip)" "a WARN line with the refusal reason"

es_amd_case "S4-U9 clip site: ximagesrc, h265 refused at 1280x720 on gfx1201" gfx1201
es_clip_gst "${ES_AMD[@]}" CLIP_VIDEO_CODEC=h265 CLIP_OUTPUT_DIMS=1280x720 T_AUDIO=0
assert_contains "$T_STDERR" \
  "[game-streamer] WARN: CLIP_VIDEO_CODEC=h265 but no VA-API HEVC encoder is usable at 1280x720, falling back to h264 (see ENCODER-CAPS)" \
  "the output size reaches the ximagesrc path too"
assert_eq 1 "$(es_caps_lines clip | grep -c .)" "exactly one ENCODER-CAPS line"
assert_match '^\[game-streamer\] WARN: ENCODER-CAPS: mode=clip requested=h265 actual=h264 encoder=vah264enc device=/dev/null gfx=gfx1201 device_id=[^ ]+ scaler=vapostproc reason=rdna4-dpb-size$' \
  "$(es_caps_lines clip)" "a WARN line with the refusal reason"
assert_match '^gst-launch-1\.0 -e ximagesrc .* ! vah264enc [^!]+ ! h264parse config-interval=1 ! qtmux faststart=true ! filesink ' \
  "$(es_pipelines)" "the VA H.264 encoder on the ximagesrc path"

es_amd_case "S4-U9 clip site: vkcapture, CLIP_VIDEO_CODEC=hevc is named h265"
es_clip "${ES_AMD[@]}" CLIP_VIDEO_CODEC=hevc
assert_contains "$T_STDOUT" "audio=1, codec=hevc)" "the capture's own line keeps the hevc spelling"
assert_match '^\[game-streamer\] ENCODER-CAPS: mode=clip requested=h265 actual=h265 encoder=vah265enc device=/dev/null gfx=gfx1151 device_id=[^ ]+ scaler=vapostproc reason=ok$' \
  "$(es_caps_lines clip)" "requested and actual h265, logged, not a WARN"

es_amd_case "S4-U9 clip site: ximagesrc, an unrecognized CLIP_VIDEO_CODEC is named h264"
es_clip_gst "${ES_AMD[@]}" CLIP_VIDEO_CODEC=av1 T_AUDIO=0
assert_match '^\[game-streamer\] ENCODER-CAPS: mode=clip requested=h264 actual=h264 encoder=vah264enc device=/dev/null gfx=gfx1151 device_id=[^ ]+ scaler=vapostproc reason=ok$' \
  "$(es_caps_lines clip)" "requested h264, the codec upstream uses, logged, not a WARN"

es_amd_case "S4-U9 clip site: the VA H.264 trial fails, x264enc makes the line a WARN"
es_clip "${ES_AMD[@]}" T_GST_PROBE_RC=1
assert_contains "$(es_pipelines)" " ! x264enc " "the software encoder runs"
assert_eq 1 "$(es_caps_lines clip | grep -c .)" "exactly one ENCODER-CAPS line"
assert_match '^\[game-streamer\] WARN: ENCODER-CAPS: mode=clip requested=h264 actual=h264 encoder=x264enc device=/dev/null gfx=gfx1151 device_id=[^ ]+ scaler=cpu reason=trial-fail$' \
  "$(es_caps_lines clip)" "a WARN line with the trial reason"

es_amd_case "S4 C16: CLIP_ZEROCOPY=1 on AMD stays on the host-map copy"
es_clip "${ES_AMD[@]}" CLIP_ZEROCOPY=1
assert_contains "$T_STDOUT" "[game-streamer]   clip capture: zero-copy not available on AMD yet, using host-map copy" \
  "the C16 line, logged, not a WARN"
assert_not_contains "$T_STDOUT" "zero-copy requested" "no zero-copy request"
assert_not_contains "$T_STDOUT" "encode chain isn't CUDA" "upstream's cudaupload test does not fire"
assert_contains "$(es_pipelines)" 'capsfilter name=vkcaps caps="video/x-raw,framerate=60/1"' \
  "no CUDA memory feature in the vkcaps filter"

es_amd_case "S4 C17: the consumer dies on AMD: the AMD text, no zero-copy retry, ximagesrc"
es_clip "${ES_AMD[@]}" CLIP_ZEROCOPY=1 T_VKCAP_DIES=1
assert_contains "$T_STDERR" \
  "[game-streamer] WARN: vkcapture-consumer died on spawn: obs-vkcapture layer not loaded in cs2 (OBS_VKCAPTURE=1 launch option?) or bad gst pipeline (see ENCODER-CAPS)" \
  "the AMD spawn-failure text"
assert_not_contains "$T_STDERR" "nvidia-drm.modeset" "no NVIDIA modeset hint"
assert_not_contains "$T_STDERR" "zero-copy consumer died" "no zero-copy retry"
assert_eq 1 "$(es_spawned | grep -c '^vkcapture-consumer ')" "one consumer spawn"
assert_contains "$T_STDERR" "WARN: vkcapture capture failed to start" "start_clip_capture falls back to ximagesrc"
assert_contains "$T_STDOUT" "rc=0 ready= go=" "the ximagesrc capture started"
assert_eq 2 "$(es_caps_lines clip | grep -c .)" "one ENCODER-CAPS line per capture start (vkcapture, then ximagesrc)"

t_done
