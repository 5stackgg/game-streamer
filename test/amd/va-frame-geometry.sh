# shellcheck shell=bash source-path=SCRIPTDIR
# Regression for real HEVC decodes with 1088 rows beside a 1080p H.264 outro.
# shellcheck disable=SC2016  # scripts expand in the clean child shell
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

for vendor in amd nvidia; do
  for dims in 1920x1080 1280x720; do
    for mode in auto cpu; do
      t_case "$vendor $dims $mode concat picture geometry"
      t_run GS_GPU_VENDOR="$vendor" GS_ENC_DIMS="$dims" GS_VIDEO_ENCODER="$mode" -- '
set -uo pipefail
. "$GS_REPO/src/lib/common.sh"
eval "$(awk '\''/^_inline_normalize_concat_inputs\(\)/{copy=1} copy{print} copy && /^}/{exit}'\'' "$GS_REPO/src/lib/inline-clip-render.sh")"
CONCAT_INPUTS=(-i padded-hevc.mp4 -i h264-outro.mp4)
FC="[0:v:0][0:a:0][1:v][1:a]concat=n=2:v=1:a=1[v][a]"
_inline_normalize_concat_inputs
printf "%s\n" "$FC"'
      assert_eq 0 "$T_RC" 'graph normalization succeeds'
      original='[0:v:0][0:a:0][1:v][1:a]concat=n=2:v=1:a=1[v][a]'
      if [ "$vendor" = nvidia ]; then
        assert_eq "$original" "$T_STDOUT" 'NVIDIA graph is byte-identical'
      else
        crop="crop=${dims/x/:}:0:0"
        assert_contains "$T_STDOUT" "[0:v:0]$crop[gs_crop_0];" 'crop the padded HEVC picture before concat'
        assert_contains "$T_STDOUT" "[1:v:0]$crop[gs_crop_1];" 'normalize the outro to the same picture'
        assert_contains "$T_STDOUT" '[gs_crop_0][0:a:0][gs_crop_1][1:a]concat=' 'preserve both audio inputs and their order'
      fi
    done
  done
done

t_case 'AMD fused overlay normalizes the chip input too'
t_run GS_GPU_VENDOR=amd GS_ENC_DIMS=1920x1080 -- '
set -uo pipefail
. "$GS_REPO/src/lib/common.sh"
eval "$(awk '\''/^_inline_normalize_concat_inputs\(\)/{copy=1} copy{print} copy && /^}/{exit}'\'' "$GS_REPO/src/lib/inline-clip-render.sh")"
CONCAT_INPUTS=(-i take.mp4 -i outro.mp4 -i chip.mov)
FC="[0:v][2:v]overlay=0:0[v0];[v0][0:a][1:v][1:a]concat=n=2:v=1:a=1[v][a]"
_inline_normalize_concat_inputs
printf "%s\n" "$FC"'
assert_eq 0 "$T_RC" 'fused normalization succeeds'
assert_contains "$T_STDOUT" '[2:v:0]crop=1920:1080:0:0[gs_crop_2];' 'chip picture uses output geometry'
assert_contains "$T_STDOUT" '[gs_crop_0][gs_crop_2]overlay=0:0[v0]' 'fused overlay keeps its input order'

t_done
