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
t_done
