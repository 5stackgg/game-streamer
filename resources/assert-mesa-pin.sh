#!/usr/bin/env bash
# Assert the image's Mesa pin and the packages needed by display tier C.
# An optional pin-file path is useful for isolated verification; the image uses the default.
set -uo pipefail

pin_file="${1:-/etc/apt/preferences.d/5stack-mesa}"
XWAYLAND_MIN=2:23.2.6-1ubuntu0.8

fail() {
  printf 'Mesa pin: %s\n' "$*" >&2
  exit 1
}

[ -r "$pin_file" ] || fail "cannot read $pin_file"
expected="$(awk '$1 == "Pin:" && $2 == "version" { n++; v=$3 } END { if (n == 1) print v; else exit 1 }' "$pin_file")" \
  || fail "expected exactly one Pin: version line in $pin_file"
dpkg --validate-version "$expected" >/dev/null 2>&1 || fail "invalid Mesa version: $expected"
if dpkg --compare-versions "$expected" ge 26.2~; then
  fail "Mesa $expected is blocked by csgo-osx-linux #4624 (26.2~ or newer)"
fi

rows="$(dpkg-query -W -f '${db:Status-Abbrev} ${binary:Package} ${source:Package} ${Version}\n')" \
  || fail 'cannot read installed package versions'
declare -A seen=()
bad=0
while read -r status binary source version; do
  [ "$status" = ii ] && [ "$source" = mesa ] || continue
  case "$binary" in *:*) ;; *) binary="$binary:amd64" ;; esac
  seen["$binary"]=1
  if [ "$version" != "$expected" ]; then
    printf 'Mesa pin: %s is %s, expected %s\n' "$binary" "$version" "$expected" >&2
    bad=1
  fi
done <<< "$rows"

required=(
  libegl-mesa0:amd64 libgbm1:amd64 libgl1-mesa-dri:amd64 libglx-mesa0:amd64
  mesa-libgallium:amd64 mesa-vulkan-drivers:amd64 mesa-va-drivers:amd64
  libegl-mesa0:i386 libgbm1:i386 libgl1-mesa-dri:i386 libglx-mesa0:i386 mesa-libgallium:i386
)
for binary in "${required[@]}"; do
  if [ -z "${seen[$binary]:-}" ]; then
    printf 'Mesa pin: missing required Mesa package %s\n' "$binary" >&2
    bad=1
  fi
done

installed_xwayland=''
if installed_xwayland="$(dpkg-query -W -f '${Version}' xwayland 2>/dev/null)"; then
  if ! dpkg --compare-versions "$installed_xwayland" ge "$XWAYLAND_MIN"; then
    printf 'Mesa pin: Xwayland %s is below %s\n' "$installed_xwayland" "$XWAYLAND_MIN" >&2
    bad=1
  fi
else
  printf 'Mesa pin: xwayland is not installed\n' >&2
  bad=1
fi

if files="$(dpkg-query -L weston 2>/dev/null)"; then
  found=0
  while IFS= read -r file; do
    case "$file" in
      */kiosk-shell.so)
        found=1
        if [ ! -f "$file" ]; then
          printf 'Mesa pin: weston kiosk-shell.so is missing on disk: %s\n' "$file" >&2
          bad=1
        fi ;;
    esac
  done <<< "$files"
  if [ "$found" = 0 ]; then
    printf 'Mesa pin: weston does not list kiosk-shell.so\n' >&2
    bad=1
  fi
else
  printf 'Mesa pin: weston is not installed\n' >&2
  bad=1
fi

if [ "$bad" = 0 ]; then
  printf 'Mesa pin OK: %s; Xwayland %s; weston kiosk-shell.so\n' "$expected" "$installed_xwayland"
fi
exit "$bad"
