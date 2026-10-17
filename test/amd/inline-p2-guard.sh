# S4 C31 and S4-D21 (part 11): the P2 guard of the inline codec choice in
# src/lib/inline-clip-render.sh on an AMD node. Until the VA-API paths of the inline
# render land, an AMD render leaves CLIP_FINAL_ENCODER at x264 when it is unset (an
# explicit value is kept) and never selects h265 (FFMPEG_H265_OK=0), each with its say
# line. The cases run the codec-choice block alone through lib/inline-codec.sh. The NVIDIA
# side is the inline-codec goldens of encode-pick.sh. S4 C19 replaces the guard, and the
# same commit deletes this file.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=lib/encode-sites.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/encode-sites.sh"
# shellcheck source=lib/inline-codec.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/inline-codec.sh"

GUARD_FINAL='[clip a1b2c3d4] final encode: h264_vaapi not enabled yet, using libx264'
GUARD_H265='[clip a1b2c3d4] h265: ffmpeg VA path not enabled yet, using libx264'
FINAL_X264='[clip a1b2c3d4] final encode: libx264 veryfast crf 22 (h264_nvenc unavailable or CLIP_FINAL_ENCODER=x264)'
HEVC_GREP_OK='[clip a1b2c3d4] h265 probe: ffmpeg hevc_nvenc OK (V....D hevc_nvenc NVIDIA NVENC hevc encoder (codec hevc))'
X264='-c:v libx264 -preset veryfast -crf 22 -pix_fmt yuv420p -profile:v high -level 4.2'

# ig_case NAME: an AMD node (es_amd_case, whose vainfo stub names gfx1151) with the ffmpeg
# stub of ic_stub_ffmpeg, whose 'ffmpeg -encoders' lists hevc_nvenc the way every ffmpeg
# build does. Pass "${ES_AMD[@]}" to ic_run first.
ig_case() {
  es_amd_case "$1"
  ic_stub_ffmpeg
}

# ig_say: the say lines of the last ic_run (its stderr lines with the job's log prefix),
# in order.
ig_say() {
  printf '%s\n' "$T_STDERR" | grep -F '[clip a1b2c3d4] ' || true
}

ig_case "S4 C31: AMD h264 render, CLIP_FINAL_ENCODER unset becomes x264"
ic_run "${ES_AMD[@]}"
assert_eq "$GUARD_FINAL"$'\n'"$FINAL_X264" "$(ig_say)" "the guard line, then upstream's libx264 line"
assert_eq "codec=h264"$'\n'"venc=$X264"$'\n'"h264=$X264"$'\n'"final_encoder=x264"$'\n'"h265_ok=gst:(unset) ffmpeg:(unset)" \
  "$T_STDOUT" "x264 set, the libx264 args for the encode sites"
assert_empty "$(t_calls ffmpeg)" "no h264_nvenc test encode"

ig_case "S4 C31: AMD h265 render, FFMPEG_H265_OK=0 makes it h264"
ic_run "${ES_AMD[@]}" CLIP_VIDEO_CODEC=h265
assert_contains "$(ig_say)" "$HEVC_GREP_OK"$'\n'"$GUARD_H265"$'\n'"[clip a1b2c3d4] h265 requested but unavailable (gst_ok=" \
  "the guard line between the hevc_nvenc grep and upstream's fallback"
assert_contains "$(ic_text)" "ffmpeg_ok=0) @EMDASH@ using h264 for this render" "the fallback names ffmpeg_ok=0"
assert_not_contains "$T_STDERR" "h265 selected" "h265 is not selected"
assert_eq "codec=h264"$'\n'"venc=$X264"$'\n'"h264=$X264"$'\n'"final_encoder=x264" "${T_STDOUT%$'\n'h265_ok=*}" \
  "h264 with the libx264 args"
assert_match 'h265_ok=gst:[01] ffmpeg:0$' "$T_STDOUT" "FFMPEG_H265_OK=0"
assert_eq "-hide_banner -encoders" "$(t_calls ffmpeg)" "only the encoder listing, no test encode"

ig_case "S4 C31: AMD, an explicit CLIP_FINAL_ENCODER=x264 is kept without the guard line"
ic_run "${ES_AMD[@]}" CLIP_FINAL_ENCODER=x264
assert_eq "$FINAL_X264" "$(ig_say)" "only upstream's libx264 line"
assert_contains "$T_STDOUT" $'\n'"final_encoder=x264"$'\n' "CLIP_FINAL_ENCODER kept"

ig_case "S4 C31: AMD, an explicit CLIP_FINAL_ENCODER=nvenc is kept and runs the h264_nvenc test encodes"
ic_run "${ES_AMD[@]}" CLIP_FINAL_ENCODER=nvenc T_FF_FULL_RC=1 T_FF_NOBREF_RC=1
assert_eq "$FINAL_X264" "$(ig_say)" "no guard line; both test encodes fail, so upstream's libx264 line"
assert_contains "$T_STDOUT" $'\n'"final_encoder=nvenc"$'\n' "CLIP_FINAL_ENCODER kept"
assert_eq 2 "$(t_calls ffmpeg | grep -c -e '-c:v h264_nvenc')" "both h264_nvenc test encodes ran"

t_done
