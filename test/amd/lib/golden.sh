# shellcheck shell=bash
# NVIDIA identity goldens for the AMD unit tests. Source it right after harness.sh:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/golden.sh"
#
# t_golden KEY ACTUAL compares ACTUAL with the golden file of KEY. Goldens are captured on
# the upstream commit the branch last merged (git merge-base HEAD origin/main), never on
# the branch, by test/amd/host/capture-goldens.sh, which runs the test files there with
# GS_GOLDEN_CAPTURE=1. In that mode t_golden writes ACTUAL instead of comparing it.
#
# A test file with goldens runs its golden cases first, from functions named golden_<topic>
# that call only code the base commit has, and stops there in capture mode, because its
# other cases test code the base commit lacks:
#
#   golden_pickers() {
#     t_case "nvidia h264 live pick"
#     t_run -- '. "$GS_REPO/src/lib/common.sh"; pick_h264_pipeline 12000 60 live'
#     t_golden pick-h264-live "$T_STDOUT"
#   }
#   golden_pickers
#   if t_capture_mode; then t_done; fi
#   # The AMD cases follow; they never run in capture mode.

GS_GOLDEN_DIR="${GS_GOLDEN_DIR:-$T_FIXTURES/goldens}"

# t_capture_mode
# Returns 0 while the goldens are being captured (GS_GOLDEN_CAPTURE=1).
t_capture_mode() {
  [ "${GS_GOLDEN_CAPTURE:-0}" = 1 ]
}

# t_golden KEY ACTUAL
# The golden file is $GS_GOLDEN_DIR/<test file name without .sh>/KEY.txt; KEY uses only
# letters, digits, dots, dashes and underscores. Before the compare or the write, every
# $T_TMP in ACTUAL becomes @TMP@ and every $GS_REPO becomes @REPO@, so goldens hold no
# temp paths. Call it after t_case.
t_golden() {
  local key="$1" actual="$2" file
  if [[ ! "$key" =~ ^[A-Za-z0-9._-]+$ ]]; then
    _t_bad "t_golden: bad key [$key]"
    return
  fi
  if [ -z "${T_TMP:-}" ]; then
    _t_bad "t_golden $key called before t_case"
    return
  fi
  file="$GS_GOLDEN_DIR/${T_FILE%.sh}/$key.txt"
  actual="${actual//"$T_TMP"/@TMP@}"
  actual="${actual//"$GS_REPO"/@REPO@}"
  if t_capture_mode; then
    mkdir -p "${file%/*}"
    printf '%s\n' "$actual" > "$file"
    _t_ok
    return
  fi
  if [ ! -f "$file" ]; then
    _t_bad "no golden $key" "missing: $file" \
      "capture it with test/amd/host/capture-goldens.sh test/amd/$T_FILE"
    return
  fi
  printf '%s\n' "$actual" > "$T_TMP/golden.actual"
  assert_file_eq "$file" "$T_TMP/golden.actual" "golden $key"
}
