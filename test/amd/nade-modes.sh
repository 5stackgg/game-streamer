# shellcheck shell=bash source-path=SCRIPTDIR
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/nade-driver.sh"

modes_case() {
  nade_case "$1"
  MODE_VENDOR=(GS_GPU_VENDOR="${2:-nvidia}")
  if [ "${2:-nvidia}" = amd ]; then
    t_fake_gpu 0000:c6:00.0 0x1002 0x1586 0x038000 renderD128
    MODE_VENDOR+=(GS_GPU_PCI_ADDRESS=0000:c6:00.0 GS_NVENC_PICK=va:vah264enc)
    t_stub vainfo 'echo "vainfo: Driver version: Mesa for Radeon (radeonsi, gfx1151, ACO)"'
  fi
}
mode_render() { nade_render "${MODE_VENDOR[@]}" "$@"; }
trace_render() {
  printf 'approach keys\n' > "$T_TMP/nade/approach"
  mode_render NADE_TRACE_EXEC=1 NADE_APPROACH_FILE="$T_TMP/nade/approach" "$@"
}
capture_encoders() { cat "$T_TMP/nade/capture.encoders" 2>/dev/null || true; }
for vendor in nvidia amd; do
  gpu=nvcudah264enc; [ "$vendor" != amd ] || gpu=vah264enc
  for mode in cpu cpu-fallback; do
    modes_case "$vendor delivery $mode skips GPU probes" "$vendor"
    setting=$mode
    if [ "$mode" = cpu-fallback ]; then : > "$LOG_DIR/cpu-fallback"; setting=auto; fi
    mode_render GS_VIDEO_ENCODER="$setting"
    assert_eq 0 "$NADE_RC" 'CPU render completes'
    assert_eq libx264 "$(nade_encoders)" 'only software delivery'
    assert_empty "$(nade_calls trial)" 'no ffmpeg GPU trial'
    assert_empty "$(t_calls vainfo)" 'no GPU metadata probe'
    assert_not_contains "$(nade_calls delivery)" -init_hw_device 'no VA device'
    assert_not_contains "$(nade_calls delivery)" hwupload 'no upload filter'
    assert_contains "$NADE_LOG" "delivery encode: encoder=libx264 (video_encoder=$mode)" 'actual CPU mode is named'
  done
  modes_case "$vendor gpu-only failed delivery ships the captured GPU video" "$vendor"
  mode_render GS_VIDEO_ENCODER=gpu NADE_FAIL_ENC='nvenc-bref h264_nvenc h264_vaapi'
  assert_eq 0 "$NADE_RC" 'delivery failure remains a successful captured upload'
  assert_not_contains "$(nade_encoders)" libx264 'GPU-only never attempts CPU delivery'
  assert_contains "$NADE_LOG" 'WARN video_encoder=gpu: no GPU delivery encode succeeded, uploading the GPU capture' 'explicit documented delivery exception'
  assert_contains "$(nade_uploads)" 'upload bytes=2048' 'original capture uploaded'
  assert_contains "$(nade_statuses)" '"status":"done"' 'terminal success'

  for fault in death unusable; do
    modes_case "$vendor $fault capture exec redo preserves the batch process" "$vendor"
    fault_env=(NADE_CAPTURE_DEATH_MODE=gpu)
    [ "$fault" != unusable ] || fault_env=(NADE_CAPTURE_UNUSABLE=first)
    trace_render "${fault_env[@]}"
    assert_eq 0 "$NADE_RC" 'CPU rerun completes'
    assert_eq "$gpu"$'\n'x264enc "$(capture_encoders)" 'one GPU take and one CPU take'
    assert_eq 2 "$(grep -c '^shell ' "$T_TMP/nade/lifecycle" || true)" 'exactly one exec rerun'
    pids=$(sed -n 's/^shell pid=\([0-9]*\).*/\1/p' "$T_TMP/nade/lifecycle" | sort -u)
    assert_eq "$(cat "$T_TMP/nade/waited.pid")" "$pids" 'exec keeps the actual process the parent waits on'
    assert_contains "$(cat "$T_TMP/nade/lifecycle")" 'redo=1 marker=1 released=0 approach=1' 'marker exists; CS2 and approach are retained across exec'
    assert_eq 2 "$(grep -c '^timeline .*bytes=14$' "$T_TMP/nade/lifecycle" || true)" 'both attempts read the approach'
    assert_eq 1 "$(grep -c '^trace .* on_exit$' "$T_TMP/nade/xtrace" || true)" 'only the rerun fires the actual EXIT trap'
    assert_no_file "$T_TMP/nade/approach" 'rerun trap removes approach after completion'
    assert_eq 1 "$(test -e "$T_TMP/nade/released" && echo 1 || echo 0)" 'CS2 releases after successful rerun'
    assert_contains "$(cat "$T_TMP/nade/parent")" 'wait rc=0 redo=unset' 'parent status correct; redo flag does not leak'
    assert_eq 2 "$(grep -c '"progress":"0.02"' "$T_TMP/nade/statuses" || true)" 'rerun resets progress'
    assert_eq 1 "$(test -e "$LOG_DIR/cpu-fallback" && echo 1 || echo 0)" 'successful redo keeps pod CPU policy'
    assert_eq libx264 "$(nade_encoders)" 'delivery obeys sticky CPU mode'
  done

  modes_case "$vendor second capture failure is bounded" "$vendor"
  trace_render NADE_CAPTURE_DEATH_MODE=all
  assert_eq 1 "$NADE_RC" 'second failure reaches the waiting parent'
  assert_eq "$gpu"$'\n'x264enc "$(capture_encoders)" 'no third take'
  assert_no_file "$LOG_DIR/cpu-fallback" 'second failure clears marker'
  assert_no_file "$T_TMP/nade/released" 'failed redo never releases CS2 early'
  assert_contains "$(cat "$T_TMP/nade/parent")" 'wait rc=1 redo=unset' 'failure and parent environment preserved'
  assert_eq 1 "$(grep -c '^trace .* on_exit$' "$T_TMP/nade/xtrace" || true)" 'only failed rerun traps'
  assert_contains "$(nade_statuses)" '"status":"error"' 'terminal error posted'

  modes_case "$vendor gpu-only dead capture must fail" "$vendor"
  trace_render GS_VIDEO_ENCODER=gpu NADE_CAPTURE_DEATH_MODE=gpu
  assert_eq 1 "$NADE_RC" 'GPU-only failed capture fails the job'
  assert_eq "$gpu" "$(capture_encoders)" 'no CPU capture'
  assert_contains "$NADE_LOG" 'WARN video_encoder=gpu: nade capture failed, CPU redo is forbidden' 'setting-specific capture refusal'
  assert_empty "$(nade_uploads)" 'dead capture never uploaded'
  assert_no_file "$LOG_DIR/cpu-fallback" 'no marker'
done

modes_case 'a second unusable nade capture also fails'
trace_render NADE_CAPTURE_UNUSABLE=all
assert_eq 1 "$NADE_RC" 'second unusable take fails'
assert_eq $'nvcudah264enc\nx264enc' "$(capture_encoders)" 'one redo only'
assert_no_file "$LOG_DIR/cpu-fallback" 'failure clears marker'
assert_no_file "$T_TMP/nade/released" 'failed capture keeps release absent'

modes_case 'cancel is checked again after exec'
trace_render NADE_CAPTURE_UNUSABLE=first NADE_CANCEL_ON_REDO=1
assert_eq 0 "$NADE_RC" 'cancelled rerun exits cleanly'
assert_eq nvcudah264enc "$(capture_encoders)" 'cancel check prevents CPU spawn'
assert_contains "$NADE_LOG" 'job already cancelled' 'rerun uses real cancel gate'
assert_eq 1 "$(grep -c '^trace .* on_exit$' "$T_TMP/nade/xtrace" || true)" 'cancelled rerun traps once'
assert_no_file "$T_TMP/nade/approach" 'cancel cleanup owns the approach'
assert_no_file "$T_TMP/nade/released" 'cancel does not release a capture it never completed'

modes_case 'later nade inherits marker but no redo flag'
: > "$LOG_DIR/cpu-fallback"
trace_render
assert_eq 0 "$NADE_RC" 'later job completes'
assert_eq x264enc "$(capture_encoders)" 'stale env GPU pick loses to the pod marker'
assert_eq 1 "$(grep -c '^shell ' "$T_TMP/nade/lifecycle" || true)" 'later job does not exec'
assert_contains "$(cat "$T_TMP/nade/parent")" 'redo=unset' 'child flag remains per render'

t_done
