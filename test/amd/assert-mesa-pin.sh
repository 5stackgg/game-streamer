#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016  # the stub bodies expand in the isolated child shell
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

MESA_PIN=25.2.8-0ubuntu0.24.04.2
MESA_PACKAGES=(
  libegl-mesa0:amd64 libgbm1:amd64 libgl1-mesa-dri:amd64 libglx-mesa0:amd64
  mesa-libgallium:amd64 mesa-vulkan-drivers:amd64 mesa-va-drivers:amd64
  libegl-mesa0:i386 libgbm1:i386 libgl1-mesa-dri:i386 libglx-mesa0:i386 mesa-libgallium:i386
)

pin_case() {
  t_case "$1"
  printf 'Package: src:mesa:any\nPin: version %s\nPin-Priority: 1001\n' "$MESA_PIN" > "$T_TMP/pin"
  local package
  for package in "${MESA_PACKAGES[@]}"; do
    printf 'ii %s mesa %s\n' "$package" "$MESA_PIN"
  done > "$T_TMP/packages"
  printf '2:23.2.6-1ubuntu0.8' > "$T_TMP/xwayland-version"
  : > "$T_TMP/kiosk-shell.so"
  printf '%s\n' "$T_TMP/kiosk-shell.so" > "$T_TMP/weston-files"
  t_stub dpkg-query '
case "${1:-}:${*: -1}" in
  -L:weston) cat "$T_TMP/weston-files" ;;
  -W:xwayland) [ "${GS_TEST_XWAYLAND_MISSING:-0}" = 1 ] && exit 1
    cat "$T_TMP/xwayland-version" ;;
  *) [ "${GS_TEST_QUERY_FAIL:-0}" = 1 ] && exit 2
    cat "$T_TMP/packages" ;;
esac'
}

pin_run() {
  t_run "$@" -- 'bash "$GS_REPO/resources/assert-mesa-pin.sh" "$T_TMP/pin"'
}

pin_case 'all packages pinned and tier C files present'
pin_run
assert_eq 0 "$T_RC" 'success'
assert_contains "$T_STDOUT" "Mesa pin OK: $MESA_PIN" 'prints the pinned version'
assert_eq '' "$T_STDERR" 'no error'

pin_case 'an i386 package off pin fails'
sed -i "s/libgbm1:i386 mesa $MESA_PIN/libgbm1:i386 mesa 25.2.8-0ubuntu0.24.04.4/" "$T_TMP/packages"
pin_run
assert_eq 1 "$T_RC" 'failure'
assert_contains "$T_STDERR" 'libgbm1:i386 is 25.2.8-0ubuntu0.24.04.4' 'names the mismatched i386 package'

pin_case 'a missing required package fails'
sed -i '/ mesa-va-drivers:amd64 /d' "$T_TMP/packages"
pin_run
assert_eq 1 "$T_RC" 'failure'
assert_contains "$T_STDERR" 'missing required Mesa package mesa-va-drivers:amd64' 'names the missing VA package'

pin_case 'an extra Mesa binary must also match the pin'
printf 'ii mesa-extra:amd64 mesa 25.2.8-0ubuntu0.24.04.4\n' >> "$T_TMP/packages"
pin_run
assert_eq 1 "$T_RC" 'failure'
assert_contains "$T_STDERR" 'mesa-extra:amd64 is 25.2.8-0ubuntu0.24.04.4' 'all source Mesa binaries are checked'

pin_case 'unrelated sources do not count as Mesa'
printf 'ii other:amd64 other-source 1.0\n' >> "$T_TMP/packages"
pin_run
assert_eq 0 "$T_RC" 'other source is ignored'

pin_case 'xwayland below its version floor fails'
printf '2:23.2.6-1ubuntu0.7' > "$T_TMP/xwayland-version"
pin_run
assert_eq 1 "$T_RC" 'failure'
assert_contains "$T_STDERR" 'Xwayland 2:23.2.6-1ubuntu0.7 is below 2:23.2.6-1ubuntu0.8' 'names both versions'

pin_case 'missing xwayland fails'
pin_run GS_TEST_XWAYLAND_MISSING=1
assert_eq 1 "$T_RC" 'failure'
assert_contains "$T_STDERR" 'xwayland is not installed' 'names missing xwayland'

pin_case 'weston without a kiosk module in its file list fails'
printf '/usr/bin/weston\n' > "$T_TMP/weston-files"
pin_run
assert_eq 1 "$T_RC" 'failure'
assert_contains "$T_STDERR" 'weston does not list kiosk-shell.so' 'names the package-content issue'

pin_case 'a listed kiosk module absent on disk fails'
rm "$T_TMP/kiosk-shell.so"
pin_run
assert_eq 1 "$T_RC" 'failure'
assert_contains "$T_STDERR" 'weston kiosk-shell.so is missing on disk' 'names the missing file'

for version in 26.2~rc1-1 26.2.0-1 26.3.0-1; do
  pin_case "blocked version $version"
  printf 'Pin: version %s\n' "$version" > "$T_TMP/pin"
  pin_run
  assert_eq 1 "$T_RC" 'failure'
  assert_contains "$T_STDERR" 'csgo-osx-linux #4624' 'names the cache blocker'
  assert_eq '' "$(t_calls dpkg-query)" 'blocked before reading packages'
done

pin_case 'invalid version fails before package queries'
printf 'Pin: version bogus\n' > "$T_TMP/pin"
pin_run
assert_eq 1 "$T_RC" 'failure'
assert_contains "$T_STDERR" 'invalid Mesa version: bogus' 'clear version error'
assert_eq '' "$(t_calls dpkg-query)" 'no package query'

pin_case 'missing pin version fails'
printf 'Package: src:mesa:any\n' > "$T_TMP/pin"
pin_run
assert_eq 1 "$T_RC" 'failure'
assert_contains "$T_STDERR" 'expected exactly one Pin: version line' 'clear pin error'

pin_case 'package query failure is fatal'
pin_run GS_TEST_QUERY_FAIL=1
assert_eq 1 "$T_RC" 'failure'
assert_contains "$T_STDERR" 'cannot read installed package versions' 'query failure is clear'
t_done
