# S3-U7 resolver cases. start_xorg integration is added after the tier C helpers.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

resolve_case() {
  local title="$1" expected="$2"
  shift 2
  t_case "$title"
  printf 'C stale\n' > "$LOG_DIR/display_tier"
  t_run "$@" -- 'set -uo pipefail
. "$GS_REPO/src/lib/xorg.sh"
_resolve_display_tier
printf "pick=<%s>\n" "$_GS_TIER_PICK"'
  assert_rc 0 'resolver succeeds under set -u'
  assert_contains "$T_STDOUT" "pick=<$expected>" 'resolved pick'
  assert_not_contains "$T_STDERR" 'unbound variable' 'no unset expansion'
}

for vendor in nvidia ''; do
  resolve_case "vendor '$vendor' ignores C" '' GS_GPU_VENDOR="$vendor" GS_DISPLAY_TIER=C
  assert_eq '' "$T_STDERR" 'no warning'
  assert_eq 'C stale' "$(cat "$LOG_DIR/display_tier")" 'no NVIDIA file write'
done

for value in '' A C c B ' C' x; do
  case "$value" in A|C) expected="$value requested" ;; *) expected='A default' ;; esac
  resolve_case "AMD requested <$value>" "$expected" GS_GPU_VENDOR=amd GS_DISPLAY_TIER="$value"
  assert_no_file "$LOG_DIR/display_tier" 'stale file removed before startup'
  case "$value" in
    ''|A|C) assert_eq '' "$T_STDERR" 'no warning' ;;
    *) assert_eq 1 "$(grep -c 'invalid GS_DISPLAY_TIER' <<< "$T_STDERR")" 'one warning' ;;
  esac
done

resolve_case 'AMD sw forces A' 'A forced:MESA_VK_WSI_DEBUG' GS_GPU_VENDOR=amd \
  GS_DISPLAY_TIER=C MESA_VK_WSI_DEBUG=sw
assert_eq 1 "$(grep -c 'tier C requested' <<< "$T_STDERR")" 'one forced-tier warning'

t_case 'the internal default constant can be tested as C'
t_run GS_GPU_VENDOR=amd -- 'set -uo pipefail
. "$GS_REPO/src/lib/xorg.sh"
_GS_DISPLAY_TIER_DEFAULT=C
_resolve_display_tier
printf "%s\n" "$_GS_TIER_PICK"'
assert_rc 0 'resolver succeeds'
assert_eq 'C default' "$T_STDOUT" 'internal C default only'
t_done
