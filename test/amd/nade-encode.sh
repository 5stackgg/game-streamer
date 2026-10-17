# S7-U9: end-to-end delivery selection with external command stubs.
# NVIDIA delivery argv/order is captured on the untouched upstream source.
# shellcheck shell=bash source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/golden.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/nade-driver.sh"

golden_nade_delivery() {
  local mode fails expected bytes
  for mode in first bref both all; do
    nade_case "NVIDIA delivery: $mode"
    case "$mode" in
      first) fails=''; expected=h264_nvenc; bytes=3072 ;;
      bref) fails=nvenc-bref; expected=$'h264_nvenc\nh264_nvenc'; bytes=3072 ;;
      both) fails='nvenc-bref h264_nvenc'; expected=$'h264_nvenc\nh264_nvenc\nlibx264'; bytes=3072 ;;
      all) fails='nvenc-bref h264_nvenc libx264'; expected=$'h264_nvenc\nh264_nvenc\nlibx264'; bytes=2048 ;;
    esac
    nade_render NADE_FAIL_ENC="$fails"
    assert_eq 0 "$NADE_RC" 'render reaches terminal success'
    assert_eq "$expected" "$(nade_encoders)" 'unchanged delivery rung order'
    assert_contains "$(nade_uploads)" "upload bytes=$bytes" 'delivery or recorded capture is uploaded'
    assert_contains "$(nade_statuses)" '"status":"done"' 'terminal API status'
    if ! t_capture_mode; then
      case "$mode" in
        first) assert_contains "$NADE_LOG" 'delivery encode: encoder=h264_nvenc' 'NVENC rung is named' ;;
        bref) assert_contains "$NADE_LOG" 'delivery encode: encoder=h264_nvenc (no B-frame refs)' 'NVENC compatibility rung is named' ;;
        both) assert_contains "$NADE_LOG" 'delivery encode: encoder=libx264' 'CPU fallback is named' ;;
        all) assert_not_contains "$NADE_LOG" 'delivery encode: encoder=' 'no encoder is claimed when all attempts fail' ;;
      esac
    fi
    t_golden "delivery-$mode" "$(nade_golden_text)"
  done
}

golden_nade_delivery
if t_capture_mode; then t_done; fi


# P2: AMD skips every NVENC delivery rung.
nade_case 'AMD P2 delivery uses libx264'
t_fake_gpu 0000:c6:00.0 0x1002 0x1586 0x038000 renderD128
nade_render GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:c6:00.0 GS_NVENC_PICK=x264enc
assert_eq 0 "$NADE_RC" 'AMD render completes'
assert_eq libx264 "$(nade_encoders)" 'only CPU delivery rung'
assert_not_contains "$(cat "$T_TMP/nade/ffmpeg.argv")" nvenc 'no ffmpeg NVENC attempt'
assert_contains "$NADE_LOG" 'delivery encode: encoder=libx264' 'selected encoder is named'
assert_contains "$(nade_uploads)" 'upload bytes=3072' 'CPU delivery uploaded'

nade_case 'AMD P2 keeps the capture when its CPU delivery fails'
t_fake_gpu 0000:c6:00.0 0x1002 0x1586 0x038000 renderD128
nade_render GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:c6:00.0 GS_NVENC_PICK=x264enc \
  NADE_FAIL_ENC=libx264
assert_eq 0 "$NADE_RC" 'captured clip remains deliverable'
assert_eq libx264 "$(nade_encoders)" 'only the CPU delivery rung is attempted'
assert_not_contains "$(cat "$T_TMP/nade/ffmpeg.argv")" nvenc 'no ffmpeg NVENC attempt'
assert_contains "$NADE_LOG" 'WARN delivery encode failed' 'original fallback warning'
assert_contains "$(nade_uploads)" 'upload bytes=2048' 'original capture uploaded'

# S7-D12: the shared helper is usable from common.sh without an inline render.
for trial_rc in 0 1 124 137; do
  nade_case "shared VA trial cache: rc=$trial_rc"
  # shellcheck disable=SC2016  # this script expands only in t_run's clean shell
  t_run NADE_FAIL_TRIAL=h264_vaapi NADE_TRIAL_RC="$trial_rc" -- '
set -uo pipefail
. "$GS_REPO/src/lib/common.sh"
GS_ENC_DIMS=1920x1080
CLIP_OUTPUT_DIMS=1920x1080
CLIP_OUTPUT_FPS=60
FFMPEG_HW_ARGS=(-init_hw_device vaapi=gsva:/dev/dri/renderD128 -filter_hw_device gsva)
for call in 1 2; do
  rc=0
  gs_va_ffmpeg_trial h264_vaapi -c:v h264_vaapi || rc=$?
  printf "call=%s rc=%s reason=%s\n" "$call" "$rc" "${VA_TRIAL_REASON:-}"
done
printf "cache=%s\n" "$(_gs_caps_get trial.ffmpeg.h264_vaapi.1920x1080)"'
  assert_eq 0 "$T_RC" 'common-only caller exits cleanly'
  case "$trial_rc" in
    0) reason=''; cache=ok; calls=1; result=0 ;;
    1) reason=trial-fail; cache=fail:1; calls=2; result=1 ;;
    *) reason=trial-timeout; cache="fail:$trial_rc"; calls=1; result=1 ;;
  esac
  assert_eq "call=1 rc=$result reason=$reason"$'\n'"call=2 rc=$result reason=$reason"$'\n'"cache=$cache" \
    "$T_STDOUT" 'result and reason survive a cached call'
  assert_eq "$calls" "$(nade_calls trial | grep -c .)" 'only the bounded initial trial runs'
done

# S7-U9: actual common.sh capability gates and the shared ffmpeg trial.
nade_amd_case() {
  nade_case "$1"
  t_fake_gpu 0000:c6:00.0 0x1002 0x1586 0x038000 renderD128
  t_stub vainfo 'printf "%s\n" "vainfo: Driver version: Mesa Gallium driver 25.2.8-0ubuntu0.24.04.2 for AMD Radeon Graphics (radeonsi, gfx1151, ACO, DRM 3.64)"'
}
nade_amd_render() {
  nade_render GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:c6:00.0 \
    GS_NVENC_PICK=va:vah264enc "$@"
  assert_eq 0 "$NADE_RC" 'AMD render completes'
  assert_not_contains "$(cat "$T_TMP/nade/ffmpeg.argv")" nvenc 'no NVIDIA ffmpeg attempt'
}
nade_caps() {
  awk -F= -v k="$1" '$1==k {v=substr($0,length(k)+2)} END {printf "%s",v}' "$LOG_DIR/encoder_caps"
}
nade_cpu_args() {
  assert_not_contains "$(nade_calls delivery)" -init_hw_device 'CPU delivery opens no VA device'
  assert_not_contains "$(nade_calls delivery)" hwupload 'CPU delivery uploads no VA frames'
}

nade_amd_case 'AMD P3 trial then h264_vaapi delivery'
nade_amd_render
assert_eq h264_vaapi "$(nade_encoders)" 'one VA delivery'
assert_eq 1 "$(nade_calls trial | grep -c .)" 'one ffmpeg trial'
assert_eq ok "$(nade_caps trial.ffmpeg.h264_vaapi.1920x1080)" 'per-pod dimension key'
assert_contains "$(nade_calls delivery)" '-init_hw_device vaapi=gsva:/dev/dri/renderD128 -filter_hw_device gsva -i ' 'device opens before input'
assert_contains "$(nade_calls delivery)" '-vf crop=1920:1080:0:0\,format=nv12\,hwupload -c:v h264_vaapi -rc_mode VBR -b:v 9M -maxrate 14M -bufsize 18M -compression_level 5 -bf 0 -g 120 -profile:v high -level 4.2' 'VA picture crop, upload and fixed defaults'
assert_contains "$NADE_LOG" 'delivery encode: encoder=h264_vaapi' 'VA selection is named'
assert_contains "$(nade_uploads)" 'upload bytes=3072' 'VA delivery uploads'
trial_order=$(while IFS= read -r line; do
  eval "set -- $line"
  kind=$(_nade_kind "$@")
  if [ "$kind" = trial ] || [ "$kind" = delivery ]; then printf '%s\n' "$kind"; fi
done < "$T_TMP/nade/ffmpeg.argv")
assert_eq $'trial\ndelivery' "$trial_order" 'one trial precedes the delivery attempt'

# Same LOG_DIR, encoder_caps and fake GPU; nade_render clears only render-local files.
nade_amd_render
assert_empty "$(nade_calls trial)" 'second render uses the same pod trial cache'
assert_eq h264_vaapi "$(nade_encoders)" 'second delivery stays VA'
assert_contains "$(nade_uploads)" 'upload bytes=3072' 'second delivery uploads'

for trial_rc in 1 124 137; do
  nade_amd_case "AMD P3 trial refusal rc=$trial_rc"
  nade_amd_render NADE_FAIL_TRIAL=h264_vaapi NADE_TRIAL_RC="$trial_rc"
  if [ "$trial_rc" = 1 ]; then attempts=2; reason=trial-fail; else attempts=1; reason=trial-timeout; fi
  assert_eq "$attempts" "$(nade_calls trial | grep -c .)" 'bounded retry policy'
  assert_eq "fail:$trial_rc" "$(nade_caps trial.ffmpeg.h264_vaapi.1920x1080)" 'failed trial cached'
  assert_eq libx264 "$(nade_encoders)" 'CPU delivery after refused trial'
  assert_contains "$NADE_LOG" "delivery encode: encoder=libx264 (reason=$reason)" 'trial fallback reason'
  nade_cpu_args
  nade_amd_render
  assert_empty "$(nade_calls trial)" 'cached failure is not retried by the next render'
  assert_contains "$NADE_LOG" "delivery encode: encoder=libx264 (reason=$reason)" 'cached reason survives'
done

nade_case 'AMD P3 no render node'
nade_render GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS= GS_RENDER_NODE= GS_NVENC_PICK=x264enc
assert_eq 0 "$NADE_RC" 'render without GPU completes'
assert_empty "$(nade_calls trial)" 'no device means no trial'
assert_eq libx264 "$(nade_encoders)" 'CPU delivery without device'
assert_contains "$NADE_LOG" 'delivery encode: encoder=libx264 (reason=no-render-node)' 'first missing gate wins'
nade_cpu_args

nade_amd_case 'AMD P3 active encoder refuses VA'
printf 'h264=x264enc\nh264_reason=no-element\n' > "$LOG_DIR/encoder_caps"
nade_amd_render GS_NVENC_PICK=x264enc
assert_empty "$(nade_calls trial)" 'capability refusal skips ffmpeg trial'
assert_eq libx264 "$(nade_encoders)" 'CPU delivery after capability refusal'
assert_contains "$NADE_LOG" 'delivery encode: encoder=libx264 (reason=no-element)' 'h264_reason is retained'
nade_cpu_args

nade_amd_case 'AMD P3 delivery failure retries libx264 without device args'
nade_amd_render NADE_FAIL_ENC=h264_vaapi
assert_eq $'h264_vaapi\nlibx264' "$(nade_encoders)" 'one VA attempt then one CPU retry'
assert_contains "$NADE_LOG" 'WARN delivery encode: h264_vaapi failed, retrying with libx264' 'runtime failure warning'
assert_contains "$NADE_LOG" 'delivery encode: encoder=libx264 (reason=retry-fail)' 'runtime fallback reason'
retry_args=$(nade_calls delivery | tail -n 1)
assert_not_contains "$retry_args" -init_hw_device 'CPU retry opens no VA device'
assert_not_contains "$retry_args" hwupload 'CPU retry uploads no VA frames'
assert_contains "$(nade_uploads)" 'upload bytes=3072' 'CPU retry result uploads'

nade_amd_case 'AMD P3 failed VA and CPU delivery keep the capture'
nade_amd_render NADE_FAIL_ENC='h264_vaapi libx264'
assert_eq $'h264_vaapi\nlibx264' "$(nade_encoders)" 'two bounded delivery attempts'
assert_contains "$NADE_LOG" 'WARN delivery encode failed' 'upstream final warning is retained'
assert_contains "$(nade_uploads)" 'upload bytes=2048' 'original capture uploads'

nade_amd_case 'AMD P3 output size and explicit VA rate controls'
nade_amd_render NADE_OUTPUT_DIMS=1280x720 NADE_OUTPUT_FPS=30 \
  NADE_FINAL_BITRATE=5M NADE_FINAL_MAXRATE=7M NADE_FINAL_BUFSIZE=10M GS_VA_FFMPEG_LEVEL=6
assert_eq ok "$(nade_caps trial.ffmpeg.h264_vaapi.1280x720)" 'global GS_ENC_DIMS matches nade output'
assert_contains "$(nade_calls trial)" 'testsrc2=size=1280x720:rate=30' 'trial uses the nade dimensions and rate'
assert_contains "$(nade_calls delivery)" '-vf crop=1280:720:0:0\,format=nv12\,hwupload' 'delivery uses the selected picture dimensions'
assert_contains "$(nade_calls delivery)" '-b:v 5M -maxrate 7M -bufsize 10M -compression_level 6 -bf 0 -g 60' 'explicit bitrate and GOP settings'
t_done
