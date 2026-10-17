# S3 change C26 and interface [31]: gs_display_tier prints A or C, the first word of
# $LOG_DIR/display_tier ('<tier> <how>[:<detail>]', interface [30]), only when GS_GPU_VENDOR
# is amd and the file exists; otherwise it prints nothing. It always returns 0 and forks
# nothing.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # the t_run scripts expand in the child shell
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# tier LINE [VAR=VALUE ...]: writes LINE to $LOG_DIR/display_tier (none writes no file,
# empty an empty file), sources common.sh and calls gs_display_tier with an empty PATH, so
# that any external command it ran would fail on stderr. Prints [<output>] rc=<rc>.
tier() {
  local line="$1"
  shift
  case "$line" in
    none) ;;
    empty) : > "$LOG_DIR/display_tier" ;;
    *) printf '%s\n' "$line" > "$LOG_DIR/display_tier" ;;
  esac
  t_run "$@" -- 'set -uo pipefail
. "$GS_REPO/src/lib/common.sh"
out="$(PATH=/nonexistent gs_display_tier)"
rc=$?
printf "[%s] rc=%s" "$out" "$rc"'
}

# tier_is LABEL EXPECTED: the last run printed EXPECTED and was silent on stderr.
tier_is() {
  assert_eq "$2" "$T_STDOUT" "$1"
  assert_empty "$T_STDERR" "$1: stderr"
}

for line in 'A default' 'A requested' 'A forced:MESA_VK_WSI_DEBUG' \
  'A fallback:no-render-node' 'C requested' 'C default'; do
  t_case "amd with display_tier [$line]"
  tier "$line" GS_GPU_VENDOR=amd
  tier_is "amd [$line]" "[${line%% *}] rc=0"
done

t_case "amd without the file prints nothing"
tier none GS_GPU_VENDOR=amd
tier_is "amd, no file" "[] rc=0"

t_case "amd with an empty file prints nothing"
tier empty GS_GPU_VENDOR=amd
tier_is "amd, empty file" "[] rc=0"

for v in nvidia AMD ''; do
  t_case "vendor [$v] ignores the file"
  tier 'C requested' GS_GPU_VENDOR="$v"
  tier_is "vendor [$v]" "[] rc=0"
done

t_case "the function body has no command substitution and no pipe"
t_run -- '. "$GS_REPO/src/lib/common.sh"; declare -f gs_display_tier'
assert_rc 0 "declare -f exit code"
assert_contains "$T_STDOUT" 'read -r tier _' "the body reads with read -r"
assert_not_contains "$T_STDOUT" '$(' "no command substitution"
assert_not_contains "$T_STDOUT" '`' "no backquote"
# With every || removed, any | left is a pipe.
assert_not_contains "${T_STDOUT//||/}" '|' "no pipe"

t_done
