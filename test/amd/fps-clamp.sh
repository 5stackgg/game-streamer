# The gs_sw_fps_clamp half of S3-U5 (S3-D9 (4), S3 interface [14]). With wsi_mode sw and
# GS_SW_WSI_FPS_MAX unset, the inputs 0, empty, 300, 120 and 60 give 120, 120, 120, 120 and
# 60; with wsi_mode hw, or with no wsi_mode file (NVIDIA), every input comes back
# unchanged. The cs2_autotune half of U5 is part 09's.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # the t_run scripts expand in the child shell
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# clamp WSI INPUTS [VAR=VALUE ...]: writes WSI to $LOG_DIR/wsi_mode (none writes no file),
# then sources common.sh and prints [<output>] for each word of INPUTS, where the word
# empty stands for the empty string.
clamp() {
  local wsi="$1" inputs="$2"
  shift 2
  if [ "$wsi" != none ]; then printf '%s\n' "$wsi" > "$LOG_DIR/wsi_mode"; fi
  t_run INPUTS="$inputs" "$@" -- 'set -uo pipefail
. "$GS_REPO/src/lib/common.sh"
for v in $INPUTS; do
  if [ "$v" = empty ]; then v=""; fi
  printf "[%s]" "$(gs_sw_fps_clamp "$v")"
done'
}

# clamp_is LABEL EXPECTED: the last run printed EXPECTED, exited 0 and was silent on stderr.
clamp_is() {
  assert_rc 0 "$1: exit code"
  assert_eq "$2" "$T_STDOUT" "$1: caps"
  assert_empty "$T_STDERR" "$1: stderr"
}

U5_INPUTS='0 empty 300 120 60'

t_case "U5: sw with GS_SW_WSI_FPS_MAX unset"
clamp sw "$U5_INPUTS"
clamp_is "sw" '[120][120][120][120][60]'

t_case "U5: hw returns every input unchanged"
clamp hw "$U5_INPUTS"
clamp_is "hw" '[0][][300][120][60]'

t_case "no wsi_mode file (NVIDIA, or before X) returns every input unchanged"
clamp none "$U5_INPUTS"
clamp_is "no file" '[0][][300][120][60]'

t_case "sw with GS_SW_WSI_FPS_MAX=60"
clamp sw "0 empty 300 61 60 30" GS_SW_WSI_FPS_MAX=60
clamp_is "max 60" '[60][60][60][60][60][30]'

t_case "sw: zero in other spellings is clamped, and a leading zero is not a higher cap"
clamp sw "00 000 060 0120 0121"
clamp_is "zeros" '[120][120][060][0120][120]'

t_case "sw: a GS_SW_WSI_FPS_MAX that is not a whole number above 0 counts as unset"
for max in abc 0 -5 1e3 ''; do
  clamp sw "300 60" GS_SW_WSI_FPS_MAX="$max"
  clamp_is "max [$max]" '[120][60]'
done

t_case "sw: a value that is not a number comes back unchanged"
clamp sw "abc 1e3 -5"
clamp_is "not a number" '[abc][1e3][-5]'

t_done
