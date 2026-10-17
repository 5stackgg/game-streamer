# shellcheck shell=bash source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/inline-driver.sh"

mode_inline_case() {
  inline_case "$1"
  MODE_INLINE_VENDOR=(GS_GPU_VENDOR="${2:-nvidia}")
  if [ "${2:-nvidia}" = amd ]; then
    t_fake_gpu 0000:c6:00.0 0x1002 0x1586 0x038000 renderD128
    MODE_INLINE_VENDOR+=(GS_GPU_PCI_ADDRESS=0000:c6:00.0 GS_NVENC_PICK=va:vah264enc GS_NVENC_PICK_H265=va:vah265enc)
    t_stub vainfo 'echo "vainfo: Driver version: Mesa for Radeon (radeonsi, gfx1151, ACO)"'
  fi
}

for vendor in nvidia amd; do
  mode_inline_case "$vendor whole CPU-only HEVC request" "$vendor"
  inline_render "${MODE_INLINE_VENDOR[@]}" GS_VIDEO_ENCODER=cpu CLIP_VIDEO_CODEC=h265
  assert_eq 0 "$INLINE_RC" 'whole render completes'
  assert_contains "$INLINE_LOG" 'final encode: libx264 veryfast crf 22 (video_encoder=cpu)' 'CPU final setup'
  assert_contains "$INLINE_LOG" 'h265 requested, but this render encodes on the CPU, using h264' 'whole render downgrades HEVC'
  assert_empty "$(inline_calls trial)$(inline_calls encoders)" 'no ffmpeg GPU trial or encoder-list probe'
  assert_empty "$(t_calls gst-inspect-1.0)$(t_calls vainfo)" 'no GPU capability probe'
  assert_contains "$(inline_calls 1)" '-c:v libx264 ' 'polish uses CPU video'
  assert_contains "$(inline_calls 2)" '-c:v libx264 ' 'matched outro uses CPU video'
  assert_contains "$(inline_calls other)" '.jpg' 'thumbnail is still extracted'
  assert_not_contains "$(inline_calls other)" nvenc 'thumbnail has no NVENC encoder'
  assert_not_contains "$(inline_calls other)" vaapi 'thumbnail opens no VA device'

  mode_inline_case "$vendor whole GPU-only refuses before its first segment" "$vendor"
  failure=(INLINE_NVENC_TRIAL=none)
  [ "$vendor" != amd ] || failure=(INLINE_FAIL_TRIAL=h264_vaapi)
  inline_render "${MODE_INLINE_VENDOR[@]}" GS_VIDEO_ENCODER=gpu "${failure[@]}"
  assert_eq 1 "$INLINE_RC" 'actual CLI failure callback returns failure'
  assert_contains "$INLINE_LOG" 'video_encoder=gpu: no GPU encoder for the final encode' 'actual terminal refusal'
  assert_empty "$(inline_calls 1)$(inline_calls 2)$(inline_calls 3)$(inline_calls 4)" 'no segment final encode is reached'
  assert_not_contains "$(cat "$T_TMP/inline/ffmpeg.argv" 2>/dev/null)" libx264 'no CPU video is attempted'

  mode_inline_case "$vendor whole GPU-only runtime failure skips CPU retry" "$vendor"
  inline_render "${MODE_INLINE_VENDOR[@]}" GS_VIDEO_ENCODER=gpu INLINE_FAIL_SITE=1 INLINE_FAIL_COUNT=1
  assert_eq 1 "$INLINE_RC" 'failed GPU polish fails the render'
  enc=h264_nvenc; [ "$vendor" != amd ] || enc=h264_vaapi
  assert_contains "$INLINE_LOG" "WARN final encode: $enc failed, video_encoder=gpu forbids the libx264 retry" 'runtime refusal reaches the whole CLI log'
  assert_eq 1 "$(inline_calls 1 | grep -c .)" 'one GPU polish attempt'
  assert_not_contains "$(inline_calls 1)" libx264 'failed polish never runs a CPU retry'
done

t_done
