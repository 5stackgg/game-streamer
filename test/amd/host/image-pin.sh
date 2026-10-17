#!/usr/bin/env bash
# Host-only image matrix. Full builds run on a suitable amd64 BuildKit host.
# The fork workflow in Task 06.6 is the required path when no such host is available.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
checks_dir="$(mktemp -d "${TMPDIR:-/tmp}/gs-image-pin.XXXXXX")"
tag="gs-amd-image-pin-$$"
cleanup() {
  docker image rm -f "$tag:normal" >/dev/null 2>&1 || true
  rm -rf "$checks_dir"
}
trap cleanup EXIT
export DOCKER_BUILDKIT=1

check_build() {
  local name="$1" expected="$2" message="$3" rc=0
  shift 3
  docker build --progress=plain --platform linux/amd64 -t "$tag:$name" "$@" . \
    > "$checks_dir/$name.log" 2>&1 || rc=$?
  if [ "$expected" = success ]; then
    if [ "$rc" != 0 ]; then cat "$checks_dir/$name.log" >&2; return 1; fi
  else
    if [ "$rc" = 0 ] || ! grep -Fq "$message" "$checks_dir/$name.log"; then
      cat "$checks_dir/$name.log" >&2
      printf '%s: expected failure naming %s, got exit %s\n' "$name" "$message" "$rc" >&2
      return 1
    fi
  fi
  printf 'PASS %s\n' "$name"
}

check_build guard failure 'Mesa 26.2.0-1 is blocked by csgo-osx-linux #4624' --build-arg MESA_VERSION=26.2.0-1
check_build missing-version failure "E: Version '0.0.0-0bogus1' for 'libegl-mesa0' was not found" --build-arg MESA_VERSION=0.0.0-0bogus1
check_build no-va failure 'missing required Mesa package mesa-va-drivers:amd64' --target mesa-test-no-va
check_build normal success ''
docker run --rm --platform linux/amd64 --entrypoint /usr/local/sbin/assert-mesa-pin "$tag:normal" \
  > "$checks_dir/versions.log" 2>&1
grep -F 'Mesa pin OK: 25.2.8-0ubuntu0.24.04.2; Xwayland ' "$checks_dir/versions.log"
grep -F 'weston kiosk-shell.so' "$checks_dir/versions.log"
check_build xwayland-floor failure 'is below 2:99' --target mesa-test-xwayland-floor
check_build no-kiosk failure 'weston kiosk-shell.so is missing on disk' --target mesa-test-no-kiosk
printf 'image-pin: 6 builds and the normal-image assertion passed\n'
