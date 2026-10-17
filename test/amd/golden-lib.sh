# Self-check of test/amd/lib/golden.sh: capture mode writes, compare mode passes on equal
# output and fails, with a diff, on changed output, a missing golden or a bad key.
# shellcheck disable=SC2016  # t_run scripts and nested bodies expand in the child shell
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/golden.sh"

# nested KEY ACTUAL: writes a one-case test file into $T_TMP that calls t_golden.
nested() {
  cat > "$T_TMP/nested.sh" <<NESTED
. "\$GS_REPO/test/amd/lib/harness.sh"
. "\$GS_REPO/test/amd/lib/golden.sh"
t_case "nested"
t_golden $1 "$2"
t_done
NESTED
}

t_case "capture mode writes the golden with temp paths replaced"
nested k1 'line one
$T_TMP/out.log'
t_run GS_GOLDEN_CAPTURE=1 GS_GOLDEN_DIR="$T_TMP/g" -- 'bash "$T_TMP/nested.sh"'
assert_rc 0 "capture exits 0"
assert_contains "$T_STDOUT" "nested.sh: 1 passed, 0 failed" "capture counts a pass"
assert_eq "line one
@TMP@/out.log" "$(cat "$T_TMP/g/nested/k1.txt")" "golden content"
t_run GS_GOLDEN_DIR="$T_TMP/g" -- 'bash "$T_TMP/nested.sh"'
assert_rc 0 "equal output passes"
nested k1 'line two
$T_TMP/out.log'
t_run GS_GOLDEN_DIR="$T_TMP/g" -- 'bash "$T_TMP/nested.sh"'
assert_rc 1 "changed output fails"
assert_contains "$T_STDERR" "golden k1" "the failure names the key"
assert_contains "$T_STDERR" "+line two" "the failure shows a diff"

t_case "a missing golden fails and names the capture script"
nested k2 'x'
t_run GS_GOLDEN_DIR="$T_TMP/g" -- 'bash "$T_TMP/nested.sh"'
assert_rc 1 "missing golden fails"
assert_contains "$T_STDERR" "no golden k2" "names the key"
assert_contains "$T_STDERR" "capture-goldens.sh test/amd/nested.sh" "names the capture command"

t_case "a bad key fails in both modes"
nested 'a/b' 'x'
t_run GS_GOLDEN_CAPTURE=1 GS_GOLDEN_DIR="$T_TMP/g" -- 'bash "$T_TMP/nested.sh"'
assert_rc 1 "bad key fails in capture mode"
assert_contains "$T_STDERR" "bad key" "says why"
assert_no_file "$T_TMP/g/nested" "nothing written"

t_case "t_capture_mode follows GS_GOLDEN_CAPTURE"
t_run GS_GOLDEN_CAPTURE=1 -- '. "$GS_REPO/test/amd/lib/harness.sh"; . "$GS_REPO/test/amd/lib/golden.sh"; t_capture_mode && echo yes'
assert_eq yes "$T_STDOUT" "capture on"
t_run -- '. "$GS_REPO/test/amd/lib/harness.sh"; . "$GS_REPO/test/amd/lib/golden.sh"; t_capture_mode || echo no'
assert_eq no "$T_STDOUT" "capture off"

t_done
