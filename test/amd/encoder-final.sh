# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # scripts and external stubs expand in their child
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/encode-sites.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/inline-codec.sh"

final_case() {
  ic_case "$1"
  FINAL_VENDOR=(GS_GPU_VENDOR="${2:-nvidia}")
  if [ "${2:-nvidia}" = amd ]; then
    t_fake_gpu 0000:c6:00.0 0x1002 0x1586 0x038000 renderD128
    FINAL_VENDOR+=(GS_GPU_PCI_ADDRESS=0000:c6:00.0 GS_NVENC_PICK=va:vah264enc GS_NVENC_PICK_H265=va:vah265enc)
    t_stub vainfo 'echo "vainfo: Driver version: Mesa for Radeon (radeonsi, gfx1151, ACO)"'
  fi
  t_stub nice '[ "${1:-}" = -n ] || exit 2
shift 2
exec "$@"'
  t_stub ffmpeg 'case " $* " in
  *" -encoders "*)
    [ "${T_FF_HEVC:-1}" != 1 ] || echo " V....D hevc_nvenc NVIDIA HEVC"
    exit 0 ;;
esac
if [ "${!#}" = - ]; then
  case " $* " in
    *" -frames:v 1 "*) exit "${FINAL_VA_TRIAL_RC:-0}" ;;
    *" -b_ref_mode "*) exit "${T_FF_FULL_RC:-0}" ;;
    *" -frames:v 8 "*) exit "${T_FF_NOBREF_RC:-0}" ;;
  esac
  exit 0
fi
exit "${FINAL_CALL_RC:-0}"'
}

# The actual source section and ffmpeg_venc run; only the CLI's terminal failure
# callback is a unit boundary. Whole-render tests exercise the actual callback.
final_sh() {
  local body="$1" script
  shift
  script=$'die_failed() { printf "DIE %s\\n" "$*" >&2; exit 23; }\n'
  script+="$(_ic_script)"
  script+=$'\n'
  script+="$body"
  t_run CLIP_RENDER_JOB_ID=a1b2c3d4e5f60718 CLIP_OUTPUT_DIMS=1920x1080 CLIP_OUTPUT_FPS=60 \
    GS_PROBE_CACHE="$T_TMP/gst-probes.env" "${FINAL_VENDOR[@]}" "$@" -- "$script"
}

for vendor in nvidia amd; do
  for mode in cpu cpu-fallback; do
    for codec in h264 h265; do
      final_case "$vendor final setup: $mode $codec" "$vendor"
      mode_env=auto
      if [ "$mode" = cpu ]; then mode_env=cpu; else : > "$LOG_DIR/cpu-fallback"; fi
      final_sh 'gs_encoder_status inline "$CLIP_CODEC_REQ" "$CLIP_VIDEO_CODEC" "${FFMPEG_VENC_ARGS[1]}" "" "${GS_INLINE_ENCODER_MODE:-}"
ffmpeg_venc -y "${FFMPEG_HW_ARGS[@]}" -i capture.mp4 "${FFMPEG_VENC_ARGS[@]}" out.mp4
printf "call_rc=%s\n" "$?"' GS_VIDEO_ENCODER="$mode_env" CLIP_VIDEO_CODEC="$codec"
      assert_eq 0 "$T_RC" 'CPU setup and encode complete'
      assert_contains "$T_STDOUT" 'codec=h264' 'CPU video codec is H.264'
      assert_contains "$T_STDOUT" 'venc=-c:v libx264 -preset veryfast -crf 22' 'CPU final arguments'
      assert_contains "$T_STDOUT" 'call_rc=0' 'actual ffmpeg_venc CPU call succeeds'
      if [ "$mode" = cpu ]; then reason='video_encoder=cpu'
      else reason='the CPU fallback is active in this pod'; fi
      assert_contains "$T_STDERR" "final encode: libx264 veryfast crf 22 ($reason)" 'CPU setup reason'
      if [ "$codec" = h265 ]; then
        assert_contains "$T_STDERR" 'h265 requested, but this render encodes on the CPU, using h264' 'CPU HEVC downgrade reason'
      fi
      assert_empty "$(t_calls gst-inspect-1.0)$(t_calls gst-launch-1.0)$(t_calls vainfo)" 'no GPU probe, including metadata'
      calls=$(t_calls ffmpeg)
      assert_eq 1 "$(grep -c . <<< "$calls")" 'one actual encode and no GPU ffmpeg trial/list probe'
      assert_not_contains "$calls" nvenc 'CPU final never invokes NVENC'
      assert_not_contains "$calls" vaapi 'CPU final opens no VA device or encoder'
    done
  done
done

for vendor in nvidia amd; do
  final_case "$vendor GPU-only has no final encoder" "$vendor"
  final_sh ':' GS_VIDEO_ENCODER=gpu T_FF_FULL_RC=1 T_FF_NOBREF_RC=1 FINAL_VA_TRIAL_RC=1
  assert_eq 23 "$T_RC" 'setup fails through the terminal callback'
  assert_contains "$T_STDERR" 'video_encoder=gpu: no GPU encoder for the final encode' 'setting-specific refusal'
  assert_not_contains "$(t_calls ffmpeg)" libx264 'no CPU encoder is invoked before refusal'

  final_case "$vendor GPU-only ignores explicit x264" "$vendor"
  final_sh ':' GS_VIDEO_ENCODER=gpu CLIP_FINAL_ENCODER=x264
  assert_eq 0 "$T_RC" 'GPU setup succeeds'
  expected=h264_nvenc; [ "$vendor" != amd ] || expected=h264_vaapi
  assert_contains "$T_STDOUT" "venc=-c:v $expected " 'GPU final encoder selected'
  assert_contains "$T_STDERR" 'video_encoder=gpu: CLIP_FINAL_ENCODER=x264 ignored' 'ignored override warns'
  assert_contains "$T_STDOUT" 'final_encoder=(unset)' 'ignored flag does not affect later sites'

  final_case "$vendor GPU-only encode failure has no CPU retry" "$vendor"
  final_sh 'rc=0
ffmpeg_venc -y "${FFMPEG_HW_ARGS[@]}" -i capture.mp4 "${FFMPEG_VENC_ARGS[@]}" out.mp4 || rc=$?
printf "final_rc=%s\n" "$rc"' GS_VIDEO_ENCODER=gpu FINAL_CALL_RC=1
  assert_eq 0 "$T_RC" 'caller inspects the failed encode'
  assert_contains "$T_STDOUT" 'final_rc=1' 'GPU failure is returned'
  assert_contains "$T_STDERR" "WARN final encode: $expected failed, video_encoder=gpu forbids the libx264 retry" 'setting-specific runtime refusal'
  assert_eq 1 "$(t_calls ffmpeg | grep -c capture.mp4)" 'only one actual encode attempt'
  assert_not_contains "$(t_calls ffmpeg)" libx264 'GPU failure invokes no CPU encode'
done

for vendor in nvidia amd; do
  for codec in h264 h265; do
    shapes=(simple)
    [ "$vendor" != amd ] || shapes=(simple overlay join)
    for shape in "${shapes[@]}"; do
      final_case "$vendor late CPU marker: $codec $shape" "$vendor"
      final_sh 'before=$(grep -Ec "^(gst-inspect-1.0|gst-launch-1.0|vainfo) " "$T_CALLS" || true)
args=(-y "${FFMPEG_HW_ARGS[@]}" -i capture.mp4)
if [ "$GS_GPU_VENDOR" = amd ]; then
  VA_VF_ARGS=(-vf format=nv12,hwupload)
  VA_UPLOAD=format=nv12,hwupload
  VA_VMAP="[vhw]"
  case "$FINAL_SHAPE" in
    simple) args+=("${VA_VF_ARGS[@]}") ;;
    overlay) args+=(-i chip.mov -filter_complex "[0:v][1:v]overlay=0:0:eof_action=pass:format=auto,format=nv12,hwupload[vout]" -map "[vout]") ;;
    join) args+=(-filter_complex "[0:v]null[v];[v]format=nv12,hwupload[vhw]" -map "[vhw]") ;;
  esac
fi
args+=("${FFMPEG_VENC_ARGS[@]}" out.mp4)
: > "$LOG_DIR/cpu-fallback"
FFMPEG_NICE=13 ffmpeg_venc "${args[@]}"
rc=$?
after=$(grep -Ec "^(gst-inspect-1.0|gst-launch-1.0|vainfo) " "$T_CALLS" || true)
printf "late_rc=%s\nafter_venc=%s\nnew_probes=%s\n" "$rc" "${FFMPEG_VENC_ARGS[*]}" "$((after-before))"' \
        CLIP_VIDEO_CODEC="$codec" FINAL_SHAPE="$shape"
      assert_eq 0 "$T_RC" 'late-marker caller completes'
      assert_contains "$T_STDOUT" 'late_rc=0' 'CPU replacement encode succeeds'
      assert_contains "$T_STDOUT" 'after_venc=-c:v libx264 -preset veryfast -crf 22' 'later sites inherit the CPU arguments'
      assert_contains "$T_STDOUT" 'new_probes=0' 'the late CPU switch performs no GPU probe'
      expected=h264_nvenc
      [ "$codec" != h265 ] || expected=hevc_nvenc
      if [ "$vendor" = amd ]; then expected=h264_vaapi; [ "$codec" != h265 ] || expected=hevc_vaapi; fi
      assert_contains "$T_STDERR" "WARN final encode: $expected skipped, the CPU fallback is active in this pod, using libx264" 'late-marker reason'
      assert_contains "$(t_calls nice | tail -n 1)" '-n 13 ffmpeg ' 'original nice prefix survives'
      call=$(t_calls ffmpeg | tail -n 1)
      assert_contains "$call" '-c:v libx264 -preset veryfast -crf 22' 'actual argv uses the CPU encoder'
      assert_not_contains "$call" nvenc 'late argv contains no NVENC encoder'
      assert_not_contains "$call" vaapi 'late argv contains no VA encoder/device'
      assert_not_contains "$call" hwupload 'late graph uploads no frames'
      assert_not_contains "$call" hvc1 'HEVC tag does not leak into H.264'
      if [ "$shape" = join ]; then
        assert_contains "$call" '-map \[v\]' 'VA graph output is mapped back to host frames'
      fi
    done
  done
done

t_done
