# shellcheck shell=bash source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/inline-driver.sh"

redo_case() {
  inline_case "$1"
  REDO_VENDOR=(GS_GPU_VENDOR="${2:-nvidia}")
  if [ "${2:-nvidia}" = amd ]; then
    t_fake_gpu 0000:c6:00.0 0x1002 0x1586 0x038000 renderD128
    REDO_VENDOR+=(GS_GPU_PCI_ADDRESS=0000:c6:00.0 GS_NVENC_PICK=va:vah264enc GS_NVENC_PICK_H265=va:vah265enc)
    t_stub vainfo 'echo "vainfo: Driver version: Mesa for Radeon (radeonsi, gfx1151, ACO)"'
  fi
}
redo_render() {
  inline_render "${REDO_VENDOR[@]}" CLIP_SEGMENTS="$(inline_segments 2)" \
    CLIP_VIDEO_CODEC=h265 CLIP_DISABLE_OUTRO=1 CLIP_POLISH_OVERLAP=0 \
    INLINE_RECORD_CAPTURE=1 INLINE_CAPTURE_DEATH_SEG=1 "$@"
}
redo_encoders() { cat "$T_TMP/inline/capture.encoders" 2>/dev/null || true; }
for vendor in nvidia amd; do
  gpu=nvcudah265enc; [ "$vendor" != amd ] || gpu=vah265enc
  redo_case "$vendor GPU death repeats exactly the same segment on CPU" "$vendor"
  redo_render INLINE_CAPTURE_DEATH_MODE=gpu
  assert_eq 0 "$INLINE_RC" 'actual render succeeds after CPU redo'
  assert_eq "$gpu"$'\n'"$gpu"$'\n'x264enc "$(redo_encoders)" 'only the failed second segment is captured again'
  assert_eq 1 "$(grep -c -- '------- SEGMENT 1/2:' <<< "$INLINE_LOG" || true)" 'first segment is not replayed'
  assert_eq 2 "$(grep -c -- '------- SEGMENT 2/2:' <<< "$INLINE_LOG" || true)" 'second segment is replayed once'
  assert_contains "$INLINE_LOG" 'capture: restarting segment 1 on the CPU' 'redo keeps the zero-based index'
  assert_eq 1 "$(test -e "$LOG_DIR/cpu-fallback" && echo 1 || echo 0)" 'successful redo keeps sticky CPU policy'
  assert_contains "$(inline_calls 3)" '-c:v libx264 ' 'GPU/CPU segments join through CPU final encode'
  order=$(awk '
    /^die / { dead=1 }
    dead && /^pause marker=1$/ { paused=1 }
    paused && /^start x264enc seg-001.mp4 marker=1$/ { ok=1 }
    END { print ok+0 }
  ' "$T_TMP/inline/capture.events")
  assert_eq 1 "$order" 'marker and pause precede the CPU attempt'

  redo_case "$vendor second CPU death fails without a third attempt" "$vendor"
  redo_render INLINE_CAPTURE_DEATH_MODE=all
  assert_eq 1 "$INLINE_RC" 'second death fails the render'
  assert_eq "$gpu"$'\n'"$gpu"$'\n'x264enc "$(redo_encoders)" 'bounded same-segment retry'
  assert_no_file "$LOG_DIR/cpu-fallback" 'second death removes sticky marker'
  assert_contains "$INLINE_LOG" 'clip capture died mid-render (segment 1)' 'original terminal error'

  redo_case "$vendor gpu-only death refuses CPU redo" "$vendor"
  redo_render GS_VIDEO_ENCODER=gpu INLINE_CAPTURE_DEATH_MODE=gpu
  assert_eq 1 "$INLINE_RC" 'GPU-only dead capture fails'
  assert_eq "$gpu"$'\n'"$gpu" "$(redo_encoders)" 'no software attempt'
  assert_contains "$INLINE_LOG" 'WARN video_encoder=gpu: capture died in segment 1, CPU redo is forbidden' 'mode-specific failure'
  assert_no_file "$LOG_DIR/cpu-fallback" 'GPU-only never activates CPU policy'

done

redo_case 'explicit CPU capture death cannot redo'
redo_render GS_VIDEO_ENCODER=cpu INLINE_CAPTURE_DEATH_MODE=all
assert_eq 1 "$INLINE_RC" 'explicit CPU death fails'
assert_eq $'x264enc\nx264enc' "$(redo_encoders)" 'only one attempt per segment'
assert_no_file "$LOG_DIR/cpu-fallback" 'no sticky marker from explicit CPU failure'
assert_not_contains "$INLINE_LOG" 'restarting segment' 'no CPU-on-CPU redo'

redo_case 'auto already using software cannot redo'
redo_render GS_NVENC_PICK=x264enc GS_NVENC_PICK_H265='' INLINE_CAPTURE_DEATH_MODE=all
assert_eq 1 "$INLINE_RC" 'automatic software capture death fails'
assert_not_contains "$INLINE_LOG" 'restarting segment' 'only a known GPU element permits redo'
assert_no_file "$LOG_DIR/cpu-fallback" 'software failure leaves no marker'

redo_case 'CPU redo that fails during spawn clears policy'
redo_render INLINE_CAPTURE_DEATH_MODE=gpu INLINE_CAPTURE_START_FAIL=cpu
assert_eq 1 "$INLINE_RC" 'CPU spawn failure terminates render'
assert_eq $'nvcudah265enc\nnvcudah265enc\nx264enc' "$(redo_encoders)" 'no second CPU spawn'
assert_no_file "$LOG_DIR/cpu-fallback" 'failed CPU spawn removes earlier marker'
assert_contains "$INLINE_LOG" 'clip capture failed to start (segment 1)' 'original startup failure'

for mode in auto gpu; do
  redo_case "$mode actual GPU capture startup failure"
  redo_render GS_VIDEO_ENCODER="$mode" INLINE_CAPTURE_START_FAIL=gpu
  if [ "$mode" = auto ]; then
    assert_eq 0 "$INLINE_RC" 'wrapper recovers GPU startup failure'
    assert_eq $'nvcudah265enc\nx264enc\nx264enc' "$(redo_encoders)" 'one CPU retry then sticky CPU next segment'
    assert_eq 1 "$(test -e "$LOG_DIR/cpu-fallback" && echo 1 || echo 0)" 'successful wrapper retry keeps policy'
  else
    assert_eq 1 "$INLINE_RC" 'GPU-only startup failure fails'
    assert_eq nvcudah265enc "$(redo_encoders)" 'no CPU startup retry'
    assert_contains "$INLINE_LOG" 'WARN: video_encoder=gpu: capture failed to start, CPU retry is forbidden' 'setting-specific startup warning'
  fi
done

redo_case 'R11 alive but unusable highlight capture keeps the prior drop behavior'
redo_render INLINE_CAPTURE_BYTES=0
assert_eq 1 "$INLINE_RC" 'all empty segments still fail'
assert_eq $'nvcudah265enc\nnvcudah265enc' "$(redo_encoders)" 'unusable live GPU capture is not a new CPU-redo trigger'
assert_not_contains "$INLINE_LOG" 'restarting segment' 'R11 scope stays unchanged'
assert_no_file "$LOG_DIR/cpu-fallback" 'unusable live highlight has no CPU marker'

t_done
