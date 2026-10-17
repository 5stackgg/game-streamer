# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # these scripts expand in their clean child shell
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/inline-driver.sh"

segment_script() {
  cat <<'SEG_SCRIPT'
set -uo pipefail
. "$GS_REPO/src/lib/common.sh"
die_failed() { echo "DIE $*" >&2; exit 31; }
awk '
  /^_inline_normalize_concat_inputs\(\)/ { on=1 }
  on { print }
  on && /^}/ { exit }
' "$GS_REPO/src/lib/inline-clip-render.sh" > "$T_TMP/normalize.sh"
. "$T_TMP/normalize.sh"
awk -v start="$SEGMENT_FN() {" '
  $0 == start { n++; on=1 }
  on { print }
  on && $0 == "}" { on=0; done++ }
  END { exit !(n==1 && done==1) }
' "$GS_REPO/src/lib/inline-clip-render.sh" > "$T_TMP/selected.sh" || exit 3
. "$T_TMP/selected.sh"
SEG_SCRIPT
}
# Use a separately built script so the function under test is read from actual source.
segment_sh() {
  local fn="$1" body="$2" script; shift 2
  script="$(segment_script)"$'\n'"$body"
  t_run SEGMENT_FN="$fn" "$@" -- "$script"
}

for scenario in uniform mixed dropped empty_slot sparse empty; do
  t_case "valid segment encoder set: $scenario"
  segment_sh _inline_set_mixed_segment_enc '
declare -a CONCAT_ENTRY=() SEG_ENC=()
case "$SEGMENT_CASE" in
  uniform) CONCAT_ENTRY=([0]=a [1]=b); SEG_ENC=([0]=nvcudah264enc [1]=nvcudah264enc) ;;
  mixed) CONCAT_ENTRY=([0]=a [1]=b); SEG_ENC=([0]=nvcudah264enc [1]=x264enc) ;;
  dropped) CONCAT_ENTRY=([0]=a); SEG_ENC=([0]=nvcudah264enc [1]=x264enc) ;;
  empty_slot) CONCAT_ENTRY=([0]=a [1]=""); SEG_ENC=([0]=nvcudah264enc [1]=x264enc) ;;
  sparse) CONCAT_ENTRY=([2]=a [8]=b); SEG_ENC=([2]=vah265enc [8]=x264enc) ;;
  empty) ;;
esac
MIXED_SEG_ENC=9
_inline_set_mixed_segment_enc
printf "mixed=%s\n" "$MIXED_SEG_ENC"' SEGMENT_CASE="$scenario"
  expected=0; case "$scenario" in mixed|sparse) expected=1 ;; esac
  assert_eq 0 "$T_RC" 'actual classifier completes'
  assert_eq "mixed=$expected" "$T_STDOUT" 'only multiple encoders among valid entries count'
done

for outcome in failed skipped ordinary; do
  t_case "C32 background polish result: $outcome"
  segment_sh reap_polish_bg '
COPY_ELIGIBLE=1
POLISH_BG_LOG="$T_TMP/polish.log"
POLISH_BG_IDX=0
printf "WARN final encode: h264_nvenc %s\n" "$POLISH_OUTCOME" > "$POLISH_BG_LOG"
true & POLISH_BG_PID=$!
reap_polish_bg
printf "copy=%s\n" "$COPY_ELIGIBLE"' POLISH_OUTCOME="$outcome"
  expected=0; [ "$outcome" != ordinary ] || expected=1
  assert_eq 0 "$T_RC" 'actual reap completes'
  assert_eq "copy=$expected" "$T_STDOUT" 'failed and skipped both prevent stream copy'
  assert_no_file "$T_TMP/polish.log" 'reap cleans its log'
done

t_case 'mixed concat graph keeps input order and audio requirements'
segment_sh _inline_mixed_concat_graph "$(cat <<'GRAPH_CASE'
SEG_DIR="$T_TMP/graph"
mkdir -p "$SEG_DIR"
printf "file '%s'\n" "$T_TMP/one clip.mp4" "$T_TMP/two.mp4" > "$SEG_DIR/concat.txt"
SEG_COUNT=2
VA_UPLOAD=""
_inline_mixed_concat_graph
printf 'argc=%s\nfirst=%s\nsecond=%s\ngraph=%s\n' "${#CONCAT_INPUTS[@]}" "${CONCAT_INPUTS[1]}" "${CONCAT_INPUTS[3]}" "$FC"
GRAPH_CASE
)"
assert_eq 0 "$T_RC" 'actual graph builder completes'
assert_empty "$T_STDERR" 'graph builder has no missing helper or other shell error'
assert_contains "$T_STDOUT" 'argc=4' 'two independent input argv pairs'
assert_contains "$T_STDOUT" "first=$T_TMP/one clip.mp4" 'path with a space stays one input'
assert_contains "$T_STDOUT" "second=$T_TMP/two.mp4" 'valid segment order'
assert_contains "$T_STDOUT" 'graph=[0:v:0][0:a:0][1:v:0][1:a:0]concat=n=2:v=1:a=1[v][a]' 'every input retains its audio requirement'

segment_case() {
  inline_case "$1"
  SEGMENT_VENDOR=(GS_GPU_VENDOR="${2:-nvidia}")
  if [ "${2:-nvidia}" = amd ]; then
    t_fake_gpu 0000:c6:00.0 0x1002 0x1586 0x038000 renderD128
    SEGMENT_VENDOR+=(GS_GPU_PCI_ADDRESS=0000:c6:00.0 GS_NVENC_PICK=va:vah264enc GS_NVENC_PICK_H265=va:vah265enc)
    t_stub vainfo 'echo "vainfo: Driver version: Mesa for Radeon (radeonsi, gfx1151, ACO)"'
  fi
}
TWO_SEGMENTS="$(inline_segments 2)"
for vendor in nvidia amd; do
  for codec in h264 h265; do
    segment_case "$vendor $codec GPU then CPU direct cuts" "$vendor"
    inline_render "${SEGMENT_VENDOR[@]}" CLIP_VIDEO_CODEC="$codec" CLIP_SEGMENTS="$TWO_SEGMENTS" \
      CLIP_DISABLE_OUTRO=1 CLIP_POLISH_OVERLAP=0 INLINE_CPU_AT_SEEK_TICK=1500 INLINE_RECORD_CAPTURE=1
    expected=nvcudah264enc
    [ "$codec" != h265 ] || expected=nvcudah265enc
    if [ "$vendor" = amd ]; then expected=vah264enc; [ "$codec" != h265 ] || expected=vah265enc; fi
    assert_eq 0 "$INLINE_RC" 'mixed whole render completes'
    assert_eq "$expected"$'\n'x264enc "$(cat "$T_TMP/inline/capture.encoders" 2>/dev/null)" 'actual captures use different encoders'
    assert_contains "$INLINE_LOG" 'mixed capture encoders, joining 2 segments with a filter graph' 'actual mixed branch'
    assert_empty "$(inline_calls copy)" 'mixed direct cuts never stream-copy'
    assert_empty "$(inline_calls 4)" 'mixed direct cuts skip concat-demuxer re-encode'
    assert_contains "$(inline_calls 3)" 'concat=n=2:v=1:a=1' 'filter graph joins the valid segments'
    assert_contains "$(inline_calls 3)" '-c:v libx264 ' 'late marker selects CPU output'
    assert_not_contains "$(inline_calls 3)" hwupload 'CPU join carries no VA upload'
  done
done

segment_case 'a failed silent pad preserves the mixed filter-graph failure'
inline_render CLIP_VIDEO_CODEC=h265 CLIP_SEGMENTS="$TWO_SEGMENTS" CLIP_DISABLE_OUTRO=1 CLIP_POLISH_OVERLAP=0 \
  INLINE_CPU_AT_SEEK_TICK=1500 INLINE_RECORD_CAPTURE=1 INLINE_NO_AUDIO_SEG=1 INLINE_PAD_FAIL=1
assert_eq 1 "$INLINE_RC" 'padless mixed join fails the render'
assert_contains "$INLINE_LOG" 'WARN failed to pad silent audio for segment 1' 'original pad warning'
assert_contains "$INLINE_LOG" 'ffmpeg concat (filter-graph) failed' 'original outro-path failure contract'
assert_contains "$(inline_calls 3)" '[1:a:0]' 'join does not silently drop the missing audio'
assert_empty "$(inline_calls copy)" 'failed mixed graph never falls back to stream copy'

segment_case 'a skipped polish cannot reuse an existing GPU outro cache'
inline_render
assert_eq 0 "$INLINE_RC" 'first GPU render creates a cache entry'
cached_before=$(inline_cached)
assert_eq 1 "$(grep -c . <<< "$cached_before")" 'one matched GPU outro'
inline_render INLINE_CPU_AT_SEEK_TICK=1
assert_eq 0 "$INLINE_RC" 'second render completes after the late CPU marker'
assert_contains "$INLINE_LOG" 'WARN final encode: h264_nvenc skipped' 'background polish records its CPU swap'
assert_not_contains "$INLINE_LOG" 'reusing cached matched outro' 'C32 blocks the cached GPU outro'
assert_empty "$(inline_calls copy)" 'second render uses no copy fast path'
assert_contains "$(inline_calls 3)" '-c:v libx264 ' 'second render joins on CPU'
assert_eq "$cached_before" "$(inline_cached)" 'old GPU cache remains untouched'

t_done
