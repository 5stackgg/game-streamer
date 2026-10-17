#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

t_case 'production image pins Mesa and verifies the final package set'
production="$(awk '/^FROM streamer AS mesa-test-/ { exit } { print }' "$GS_REPO/Dockerfile")"
pin_run="$(awk '
  function flush() { if (index(block, "src:mesa:any")) printf "%s", block; block="" }
  /^RUN / { flush(); block=$0 ORS; next }
  /^[[:space:]]/ { if (block != "") block=block $0 ORS; next }
  { flush() }
  END { flush() }
' <<< "$production")"

assert_contains "$production" 'FROM nvidia/cuda:12.6.3-base-ubuntu24.04 AS streamer' 'shared CUDA base'
assert_contains "$production" 'ARG MESA_VERSION=25.2.8-0ubuntu0.24.04.2' 'exact default'
assert_contains "$production" 'COPY resources/assert-mesa-pin.sh /usr/local/sbin/assert-mesa-pin' 'assertion available before the pin RUN'
assert_contains "$pin_run" 'apt-get update' 'refresh package lists'
assert_contains "$pin_run" 'dpkg --validate-version "$MESA_VERSION"' 'reject malformed build arguments'
assert_contains "$pin_run" 'dpkg --compare-versions "$MESA_VERSION" ge 26.2~' 'block new cache-breaking Mesa'
assert_contains "$pin_run" 'csgo-osx-linux #4624' 'guard explains the blocker'
assert_contains "$pin_run" 'Package: src:mesa:any' 'all Mesa source binaries pinned'
assert_contains "$pin_run" 'Pin: version %s' 'exact build argument pin'
assert_contains "$pin_run" 'Pin-Priority: 1001' 'downgrades allowed'
assert_eq 1 "$(grep -c 'apt-get install' <<< "$pin_run")" 'one apt install transaction'
assert_match 'src:mesa:any.*apt-get install' "${pin_run//$'\n'/ }" 'preferences precede installation'
assert_contains "$pin_run" 'apt-get install -y --no-install-recommends' 'no recommended packages'
for package in libegl-mesa0 libgbm1 libgl1-mesa-dri libglx-mesa0 mesa-libgallium mesa-vulkan-drivers mesa-va-drivers \
  libegl-mesa0:i386 libgbm1:i386 libgl1-mesa-dri:i386 libglx-mesa0:i386 mesa-libgallium:i386; do
  assert_contains "$pin_run" "\"$package=\${MESA_VERSION}\"" "versioned $package"
done
assert_contains "$pin_run" 'vainfo weston xwayland' 'unversioned display packages in the same transaction'
for package in mesa-vulkan-drivers:i386 mesa-va-drivers:i386 weston:i386 xwayland:i386 vainfo:i386; do
  assert_not_contains "$pin_run" "$package" "no unnecessary $package"
done
assert_contains "$pin_run" '/usr/local/sbin/assert-mesa-pin' 'verify immediately'
assert_contains "$pin_run" 'rm -rf /var/lib/apt/lists/*' 'clear apt lists'
assert_eq 2 "$(grep -Ec '^ *(RUN|&&) /usr/local/sbin/assert-mesa-pin( |$)' <<< "$production")" 'two executed production assertions'
assert_eq 'RUN /usr/local/sbin/assert-mesa-pin' "$(grep '^RUN ' <<< "$production" | tail -1)" 'assertion is the last production RUN'
assert_match 'rm -rf out.*RUN /usr/local/sbin/assert-mesa-pin.*WORKDIR /opt/game-streamer' "${production//$'\n'/ }" 'final assertion follows the consumer and motion builds'
assert_not_contains "$production" 'COPY test/' 'tests excluded'
assert_not_contains "$production" 'COPY . ' 'no entire-context copy'

t_case 'BuildKit negative targets are isolated from the default image'
dockerfile="$(cat "$GS_REPO/Dockerfile")"
for stage in mesa-test-no-va mesa-test-xwayland-floor mesa-test-no-kiosk; do
  stage_run="$(awk -v stage="$stage" '
    /^FROM / { active=($0 == "FROM streamer AS " stage); next }
    active { print }
  ' <<< "$dockerfile")"
  assert_contains "$dockerfile" "FROM streamer AS $stage" "$stage starts with the completed image"
  assert_contains "$stage_run" '&& /usr/local/sbin/assert-mesa-pin' "$stage rechecks the modified image"
done
assert_contains "$dockerfile" 'apt-get purge -y mesa-va-drivers:amd64' 'remove required VA package'
assert_contains "$dockerfile" 'XWAYLAND_MIN=2:99/' 'raise the accepted Xwayland floor'
assert_contains "$dockerfile" "grep '/kiosk-shell\\.so$' | xargs -r rm -f" 'remove the packaged kiosk file'
assert_eq 'FROM streamer' "$(grep '^FROM ' <<< "$dockerfile" | tail -1)" 'default target skips failure branches'
t_done
