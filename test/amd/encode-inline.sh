# S4-U7, inline part: the ffmpeg calls and log lines of src/lib/inline-clip-render.sh on
# NVIDIA (GS_GPU_VENDOR unset), run end to end with the stubs of lib/inline-driver.sh and
# compared with goldens captured on the upstream commit: the four encode sites for h264
# and h265 requests, the h264_nvenc retry of ffmpeg_venc at each site with its WARN line,
# the 'final encode' line and the h265 probe lines. Then S4-U16, the S4 C32 retry guards:
# two goldens, then the behaviour cases, which need C32.
#
# Render shapes (on top of the driver's defaults: 1920x1080 at 60 fps, a chip, the outro):
#   a  one segment, CLIP_MAX_FUSED_SEGMENTS=0: site 1 (the chip polish of segment 0),
#      site 2 (the outro transcode) and the -c copy concat of the outro fast path
#   b  two segments: site 1, then site 3 with the concat-only graph (segment 1 skips the
#      polish, so the fast path is refused)
#   c  two segments, CLIP_MAX_FUSED_SEGMENTS=6: site 3 with the fused graph
#   d  two segments, CLIP_DISABLE_OUTRO=1, the -c copy concat refused: site 1, then site 4
# The retry goldens use shapes that never take the fast path, except at site 2, which
# runs only in the fast path: that golden stops at the retry call (inline_golden_text
# cut), because what follows a retry there changes with the S4 C32 guard.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2119  # inline_render takes optional VAR=VALUE pairs
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=lib/golden.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/golden.sh"
# shellcheck source=lib/inline-driver.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/inline-driver.sh"

TWO_SEGMENTS="$(inline_segments 2)"
SHAPE=()

# shape a|b|c|d: sets SHAPE to the inline_render arguments of that render shape.
shape() {
  case "$1" in
    a) SHAPE=() ;;
    b) SHAPE=(CLIP_SEGMENTS="$TWO_SEGMENTS") ;;
    c) SHAPE=(CLIP_SEGMENTS="$TWO_SEGMENTS" CLIP_MAX_FUSED_SEGMENTS=6) ;;
    d) SHAPE=(CLIP_SEGMENTS="$TWO_SEGMENTS" CLIP_DISABLE_OUTRO=1 INLINE_COPY_FAIL=1) ;;
  esac
}

# The sites each shape reaches, in call order (inline_sites).
declare -A SHAPE_SITES=([a]="1 2 copy" [b]="1 3" [c]="3" [d]="1 copy 4")

golden_sites() {
  local codec s
  for codec in h264 h265; do
    for s in a b c d; do
      inline_case "$codec request, shape $s"
      shape "$s"
      inline_render CLIP_VIDEO_CODEC="$codec" "${SHAPE[@]}"
      assert_eq 0 "$INLINE_RC" "render exits 0"
      assert_eq "${SHAPE_SITES[$s]}" "$(inline_sites)" "sites"
      t_golden "$codec-$s" "$(inline_golden_text)"
    done
  done
}

golden_retry() {
  inline_case "h264_nvenc fails at site 1 (shape b): libx264 retry in the polish subshell"
  shape b
  inline_render INLINE_FAIL_SITE=1 "${SHAPE[@]}"
  assert_eq 0 "$INLINE_RC" "render exits 0"
  assert_eq "1 1 3" "$(inline_sites)" "sites"
  assert_contains "$INLINE_LOG" "  polish[0]: [clip 0123abcd] WARN final encode: h264_nvenc failed" \
    "WARN line under the polish prefix"
  t_golden retry-site1 "$(inline_golden_text)"

  inline_case "h264_nvenc fails at site 2 (shape a): libx264 retry of the outro transcode"
  inline_render INLINE_FAIL_SITE=2
  assert_eq 0 "$INLINE_RC" "render exits 0"
  assert_match '^1 2 2( |$)' "$(inline_sites)" "site 2 runs twice"
  assert_contains "$(inline_calls 2 | tail -n 1)" "-c:v libx264" "the retry encodes with libx264"
  assert_contains "$INLINE_LOG" "WARN final encode: h264_nvenc failed" "WARN line"
  t_golden retry-site2-cut "$(inline_golden_text cut)"

  inline_case "h264_nvenc fails at site 3 (shape b, concat-only graph)"
  shape b
  inline_render INLINE_FAIL_SITE=3 "${SHAPE[@]}"
  assert_eq 0 "$INLINE_RC" "render exits 0"
  assert_eq "1 3 3" "$(inline_sites)" "sites"
  assert_contains "$INLINE_LOG" "WARN final encode: h264_nvenc failed" "WARN line"
  t_golden retry-site3 "$(inline_golden_text)"

  inline_case "h264_nvenc fails at site 3 (shape c, fused graph)"
  shape c
  inline_render INLINE_FAIL_SITE=3 "${SHAPE[@]}"
  assert_eq 0 "$INLINE_RC" "render exits 0"
  assert_eq "3 3" "$(inline_sites)" "sites"
  assert_contains "$INLINE_LOG" "WARN final encode: h264_nvenc failed" "WARN line"
  t_golden retry-site3-fused "$(inline_golden_text)"

  inline_case "h264_nvenc fails at site 4 (shape d)"
  shape d
  inline_render INLINE_FAIL_SITE=4 "${SHAPE[@]}"
  assert_eq 0 "$INLINE_RC" "render exits 0"
  assert_eq "1 copy 4 4" "$(inline_sites)" "sites"
  assert_contains "$INLINE_LOG" "WARN final encode: h264_nvenc failed" "WARN line"
  t_golden retry-site4 "$(inline_golden_text)"
}

golden_choice() {
  inline_case "h264_nvenc passes its test encode only without -b_ref_mode"
  inline_render INLINE_NVENC_TRIAL=nobref
  assert_eq 0 "$INLINE_RC" "render exits 0"
  assert_contains "$INLINE_LOG" "final encode: h264_nvenc p6/hq 9M (max 14M), no B-frame refs" \
    "final encode line"
  t_golden final-nobref "$(inline_golden_text)"

  inline_case "CLIP_FINAL_ENCODER=x264"
  inline_render CLIP_FINAL_ENCODER=x264
  assert_eq 0 "$INLINE_RC" "render exits 0"
  assert_contains "$INLINE_LOG" \
    "final encode: libx264 veryfast crf 22 (h264_nvenc unavailable or CLIP_FINAL_ENCODER=x264)" \
    "final encode line"
  t_golden final-x264 "$(inline_golden_text)"

  inline_case "no h264_nvenc test encode passes"
  inline_render INLINE_NVENC_TRIAL=none
  assert_eq 0 "$INLINE_RC" "render exits 0"
  assert_contains "$INLINE_LOG" \
    "final encode: libx264 veryfast crf 22 (h264_nvenc unavailable or CLIP_FINAL_ENCODER=x264)" \
    "final encode line"
  t_golden final-no-nvenc "$(inline_golden_text)"

  inline_case "h265 request with no gst HEVC encoder"
  inline_render CLIP_VIDEO_CODEC=h265 GS_NVENC_PICK_H265=none
  assert_eq 0 "$INLINE_RC" "render exits 0"
  assert_contains "$INLINE_LOG" "h265 requested but unavailable (gst_ok=0 ffmpeg_ok=1)" "h265 choice"
  t_golden h265-no-gst-hevc "$(inline_golden_text)"

  inline_case "h265 request with no hevc_nvenc in ffmpeg"
  inline_render CLIP_VIDEO_CODEC=h265 INLINE_FFMPEG_NO_HEVC=1
  assert_eq 0 "$INLINE_RC" "render exits 0"
  assert_contains "$INLINE_LOG" "h265 requested but unavailable (gst_ok=1 ffmpeg_ok=0)" "h265 choice"
  t_golden h265-no-ffmpeg-hevc "$(inline_golden_text)"
}

# S4-U16, the S4 C32 retry guards, on the S4-U16 render (shape a). The both-fail and
# no-failure renders run the same calls with and without C32, so their calls at sites 1
# to 3, the -c copy concat and their 'OUTRO:', 'STEP 9', '  concat:' and 'WARN final
# encode' lines are goldens (inline_golden_text u16).
golden_retry_guard() {
  inline_case "S4-U16: h264_nvenc and its libx264 retry both fail at site 2"
  inline_render INLINE_FAIL_SITE=2 INLINE_FAIL_COUNT=2
  assert_eq 0 "$INLINE_RC" "render exits 0"
  assert_contains "$INLINE_LOG" "  concat: outro transcode failed" "transcode failure line"
  assert_not_contains "$INLINE_LOG" "retried with libx264" "no retry note"
  assert_empty "$(inline_calls copy)" "no -c copy concat"
  assert_empty "$(inline_cached)" "OUTRO_CACHE_DIR stays empty"
  assert_eq "1 2 2 3" "$(inline_sites)" "sites"
  assert_contains "$(inline_calls 3)" "-c:v libx264" "site 3 encodes with libx264"
  t_golden u16-both-fail "$(inline_golden_text u16)"

  inline_case "S4-U16: no failure"
  inline_render
  assert_eq 0 "$INLINE_RC" "render exits 0"
  assert_contains "$INLINE_LOG" "transcoding outro to match polished segments" "outro transcode line"
  assert_contains "$INLINE_LOG" "  concat: stream-copy OK" "stream-copy line"
  assert_eq "1 2 copy" "$(inline_sites)" "sites"
  assert_match '^outro-[0-9a-f]{12}\.mp4$' "$(inline_cached)" "one cached outro, no staging file"
  t_golden u16-no-failure "$(inline_golden_text u16)"
}

golden_sites
golden_retry
golden_choice
golden_retry_guard
if t_capture_mode; then t_done; fi

# S4-U16 behaviour cases. They fail without S4 C32, where a libx264 retry reaches the
# stream-copy fast path.
inline_case "S4-U16: h264_nvenc fails at site 2, then a render with no failure"
inline_render INLINE_FAIL_SITE=2
assert_eq 0 "$INLINE_RC" "render exits 0"
assert_match 'WARN final encode: h264_nvenc failed.*  concat: outro transcode retried with libx264, falling back to re-encode' \
  "$INLINE_LOG" "WARN line, then the retry note"
assert_empty "$(inline_cached)" "no outro and no staging file in OUTRO_CACHE_DIR"
assert_empty "$(inline_calls copy)" "no -c copy concat"
assert_eq "1 2 2 3" "$(inline_sites)" "sites"
assert_contains "$INLINE_LOG" "STEP 9: ffmpeg concat 2 segments (with outro, filter-graph)" "STEP 9 line"
assert_contains "$(inline_calls 3)" "concat=n=2" "site 3 runs the concat-only graph"
assert_contains "$(inline_calls 3)" "-c:v libx264" "site 3 encodes with libx264"
inline_render
assert_eq 0 "$INLINE_RC" "second render exits 0"
assert_contains "$INLINE_LOG" "transcoding outro to match polished segments" "the outro is transcoded again"
assert_not_contains "$INLINE_LOG" "reusing cached matched outro" "no cached outro is reused"
assert_contains "$INLINE_LOG" "  concat: stream-copy OK" "stream-copy line"
assert_eq "1 2 copy" "$(inline_sites)" "second render sites"
assert_match '^outro-[0-9a-f]{12}\.mp4$' "$(inline_cached)" "exactly one cached outro"

inline_case "S4-U16: h264_nvenc fails at site 1"
inline_render INLINE_FAIL_SITE=1
assert_eq 0 "$INLINE_RC" "render exits 0"
assert_contains "$INLINE_LOG" "  polish[0]: [clip 0123abcd] WARN final encode: h264_nvenc failed" \
  "WARN line under the polish prefix"
assert_empty "$(inline_calls 2)" "no site 2 transcode"
assert_empty "$(inline_calls copy)" "no -c copy concat"
assert_eq "1 1 3" "$(inline_sites)" "sites"
assert_contains "$INLINE_LOG" "STEP 9: ffmpeg concat 2 segments (with outro, filter-graph)" "STEP 9 line"
assert_contains "$(inline_calls 3)" "concat=n=2" "site 3 runs the concat-only graph"
assert_contains "$(inline_calls 3)" "-c:v h264_nvenc" "site 3 encodes with h264_nvenc"

t_done
