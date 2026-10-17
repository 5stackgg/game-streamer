# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # child scripts and stub bodies expand when they run
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

mode_case() {
  t_case "$1"
  MODE_VENDOR=(GS_GPU_VENDOR="${2:-nvidia}")
  if [ "${2:-nvidia}" = amd ]; then
    t_fake_gpu 0000:c6:00.0 0x1002 0x1586 0x038000 renderD128
    MODE_VENDOR+=(GS_GPU_PCI_ADDRESS=0000:c6:00.0)
  fi
  t_stub gst-inspect-1.0 'case " ${MODE_ELEMENTS-nvcudah264enc nvcudah265enc cudaupload cudaconvertscale} " in
  *" ${1:-} "*) echo "Element Properties:" ;;
  *) exit 1 ;;
esac'
  t_stub gst-launch-1.0 'exit "${MODE_GST_RC:-0}"'
  t_stub vainfo 'printf "%s\n" "vainfo: Driver version: Mesa for Radeon (radeonsi, ${MODE_GFX:-gfx1151}, ACO)"'
}

# mode_sh BODY [VAR=VALUE...]: actual common.sh in a clean child shell.
mode_sh() {
  local body="$1"
  shift
  t_run "${MODE_VENDOR[@]}" GS_PROBE_CACHE="$T_TMP/gst-probes.env" "$@" -- \
    'set -uo pipefail
. "$GS_REPO/src/lib/common.sh"
'"$body"
}

# Explicit auto and an absent env are equivalent, including the marker behavior.
for raw in absent auto gpu cpu unknown; do
  for marker in 0 1; do
    mode_case "mode=$raw marker=$marker"
    mode_args=()
    [ "$raw" = absent ] || mode_args+=(GS_VIDEO_ENCODER="$raw")
    [ "$marker" = 0 ] || : > "$LOG_DIR/cpu-fallback"
    case "$raw" in
      gpu|cpu) expected="$raw" ;;
      *) if [ "$marker" = 1 ]; then expected=cpu-fallback; else expected=auto; fi ;;
    esac
    mode_sh 'printf "first="; gs_video_encoder_mode
printf "\nsecond=%s\n" "$(gs_video_encoder_mode)"' "${mode_args[@]}"
    assert_eq 0 "$T_RC" 'mode function is available'
    assert_eq "first=$expected"$'\n'"second=$expected" "$T_STDOUT" 'clean stdout in each subshell'
    if [ "$raw" = unknown ]; then
      assert_eq 2 "$(grep -c WARN <<< "$T_STDERR")" 'unknown value warns once per call on stderr'
    else
      assert_empty "$T_STDERR" 'known value is silent'
    fi
  done
done

for vendor in nvidia amd; do
  for raw in cpu auto absent unknown; do
    mode_case "$vendor CPU picks override warm env/cache: $raw" "$vendor"
    mode_args=()
    [ "$raw" = absent ] || mode_args+=(GS_VIDEO_ENCODER="$raw")
    [ "$raw" = cpu ] || : > "$LOG_DIR/cpu-fallback"
    printf 'GS_NVENC_PICK=nvcudah264enc\nGS_NVENC_PICK_H265=nvcudah265enc\n' > "$T_TMP/gst-probes.env"
    before_cache=$(cat "$T_TMP/gst-probes.env")
    mode_sh 'h264=$(pick_h264_pipeline 60 8000 live)
_ensure_nvenc_pick h264
_ensure_nvenc_pick h265
rc=0; h265_available || rc=$?
printf "h264=%s\nparent=%s,%s\nhevc=%s\n" "$h264" "$GS_NVENC_PICK" "$GS_NVENC_PICK_H265" "$rc"
pick_scale_convert 1280 720 60 h264' "${mode_args[@]}" \
      GS_NVENC_PICK=va:vah264enc GS_NVENC_PICK_H265=nvcudah265enc
    assert_eq 0 "$T_RC" 'CPU selection succeeds'
    assert_contains "$T_STDOUT" 'h264=x264enc tune=zerolatency' 'child shell selects CPU'
    assert_contains "$T_STDOUT" 'parent=x264enc,none' 'parent picks match the child'
    assert_contains "$T_STDOUT" 'hevc=1' 'CPU HEVC is unavailable'
    assert_contains "$T_STDOUT" 'videoscale ! video/x-raw,width=1280,height=720' 'CPU scale path'
    assert_eq "$before_cache" "$(cat "$T_TMP/gst-probes.env")" 'CPU picks never enter the persistent GPU cache'
    assert_empty "$(t_calls gst-inspect-1.0)$(t_calls gst-launch-1.0)$(t_calls vainfo)" 'no GPU probe or trial'
  done
done

mode_case 'CPU mode ignores both forced GPU elements'
mode_sh '_ensure_nvenc_pick h264; _ensure_nvenc_pick h265
printf "%s,%s\n" "$GS_NVENC_PICK" "$GS_NVENC_PICK_H265"' \
  GS_VIDEO_ENCODER=cpu GS_NVENC_ELEMENT=nvcudah264enc GS_NVENC_H265_ELEMENT=va
assert_eq x264enc,none "$T_STDOUT" 'both forced elements lose to CPU mode'
assert_contains "$T_STDERR" 'GS_NVENC_ELEMENT=nvcudah264enc ignored' 'H.264 override warns'
assert_contains "$T_STDERR" 'GS_NVENC_H265_ELEMENT=va ignored' 'HEVC override warns'
assert_empty "$(t_calls gst-inspect-1.0)$(t_calls gst-launch-1.0)" 'ignored overrides do not probe'
assert_eq 2 "$(grep -c ignored <<< "$T_STDERR")" 'one warning per ignored override'

for codec in h264 h265; do
  for origin in env file; do
    mode_case "GPU mode clears a stale $codec CPU pick from $origin"
    var=GS_NVENC_PICK; expected=nvcudah264enc
    if [ "$codec" = h265 ]; then var=GS_NVENC_PICK_H265; expected=nvcudah265enc; fi
    mode_args=()
    if [ "$origin" = env ]; then mode_args+=("$var=x264enc")
    else printf '%s=x264enc\n' "$var" > "$T_TMP/gst-probes.env"; fi
    mode_sh '_ensure_nvenc_pick "$MODE_CODEC"
printf "%s\n" "${!MODE_PICK_VAR}"' GS_VIDEO_ENCODER=gpu MODE_CODEC="$codec" MODE_PICK_VAR="$var" "${mode_args[@]}"
    assert_eq 0 "$T_RC" 'GPU resolve succeeds'
    assert_eq "$expected" "$T_STDOUT" 'stale x264enc does not short-circuit the GPU resolver'
    assert_contains "$T_STDERR" 'video_encoder=gpu: ignoring cached x264enc' 'stale pick warning'
    assert_contains "$(t_calls gst-inspect-1.0)" "$expected" 'GPU is probed afresh'
  done
done

for vendor in nvidia amd; do
  mode_case "$vendor GPU mode has no encoder" "$vendor"
  mode_sh 'rc=0; value=$(pick_h264_pipeline 60 8000) || rc=$?
printf "rc=%s value=%s\n" "$rc" "$value"' \
    GS_VIDEO_ENCODER=gpu GS_NVENC_ELEMENT=nvcudah264enc MODE_ELEMENTS=
  assert_eq 'rc=1 value=' "$T_STDOUT" 'GPU mode refuses software output'
  assert_contains "$T_STDERR" 'video_encoder=gpu: no GPU H.264 encoder, not using x264enc' 'setting is named'
  assert_contains "$T_STDERR" 'forced but unavailable' 'forced missing element warning is retained'
done

mode_case 'AMD GPU mode refuses a VA capability failure' amd
mode_sh 'a=0; b=0; c=0
h264=$(pick_h264_pipeline 60 8000) || a=$?
h265=$(pick_h265_pipeline 60 8000) || b=$?
h265_available || c=$?
printf "h264=%s:%s\nh265=%s:%s\navailable=%s\n" "$a" "$h264" "$b" "$h265" "$c"' \
  GS_VIDEO_ENCODER=gpu GS_NVENC_PICK=va:vah264enc GS_NVENC_PICK_H265=va:vah265enc MODE_GFX=polaris10
assert_eq $'h264=1:\nh265=1:\navailable=1' "$T_STDOUT" 'every VA caller refuses instead of returning CPU'
assert_contains "$T_STDERR" 'video_encoder=gpu:' 'VA refusal names the setting'
assert_contains "$T_STDERR" 'pre-vcn-unsoaked' 'VA refusal keeps the capability reason'
assert_empty "$(t_calls gst-launch-1.0)" 'static VA refusal starts no pipeline'

for vendor in nvidia amd; do
  mode_case "$vendor CPU HEVC clip falls back with the setting reason" "$vendor"
  mode_sh '. "$GS_REPO/src/lib/clip-capture.sh"
_clip_resolve_encoder 120 16000
printf "%s:%s\n" "$CLIP_CODEC" "$CLIP_ENC"' GS_VIDEO_ENCODER=cpu CLIP_VIDEO_CODEC=h265
  assert_eq 0 "$T_RC" 'CPU clip codec resolves'
  assert_contains "$T_STDOUT" 'h264:x264enc ' 'CPU HEVC becomes H.264'
  assert_contains "$T_STDERR" 'video_encoder=cpu: encoding on the CPU (x264enc), HEVC becomes H.264' 'CPU-specific reason precedes the old fallback line'
  assert_empty "$(t_calls gst-inspect-1.0)$(t_calls gst-launch-1.0)$(t_calls vainfo)" 'CPU codec does not probe GPU'
done

for vendor in nvidia amd; do
  mode_case "$vendor CPU mode overrides the legacy bogus preset" "$vendor"
  mode_sh '_ensure_nvenc_pick h264; _ensure_nvenc_pick h265
printf "%s:%s\n" "$GS_NVENC_PICK" "$GS_NVENC_PICK_H265"' GS_VIDEO_ENCODER=cpu \
    GS_NVENC_PICK=nvh264enc:bogus GS_NVENC_PICK_H265=nvh265enc:bogus
  assert_eq 0 "$T_RC" 'CPU mode accepts the stale environment'
  assert_eq x264enc:none "$T_STDOUT" 'legacy presets lose to policy'
  assert_empty "$(t_calls gst-inspect-1.0)$(t_calls gst-launch-1.0)" 'legacy presets do not trigger probes'
  assert_no_file "$T_TMP/gst-probes.env" 'CPU choice is never cached'
done

t_done
