# shellcheck shell=bash
# shellcheck disable=SC2034  # T_STDOUT, T_STDERR and T_RC are read by the test files
# Plain-bash helpers for the AMD unit tests under test/amd/.
#
# A test file sources this, then runs cases:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
#   t_case "amd with a valid address"
#   t_fake_gpu 0000:c6:00.0 0x1002 0x1586 0x038000 renderD128
#   t_run GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:c6:00.0 -- \
#     '. "$GS_REPO/src/lib/common.sh"; echo "$MESA_VK_DEVICE_SELECT"'
#   assert_eq "1002:1586!" "$T_STDOUT" "device select"
#   t_done
#
# The tests need bash 4 or newer. Run them with test/amd/lib/docker.sh (ubuntu:24.04, the
# image's release) or inside the image, never under the macOS bash 3.2.
# Nothing here writes outside the per-file temp root, which is removed on exit.

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "test/amd needs bash 4 or newer; run test/amd/lib/docker.sh" >&2
  exit 2
fi

GS_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
T_FIXTURES="$GS_REPO/test/amd/fixtures"
T_FILE="$(basename "${BASH_SOURCE[1]:-$0}")"
T_PASS=0
T_FAIL=0
T_NAME=""
T_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gs-amd-test.XXXXXX")"
trap 'rm -rf "$T_ROOT"' EXIT
T_PATH0="$PATH"
export GS_REPO T_FIXTURES

# t_case NAME
# Starts a case: a fresh temp dir with LOG_DIR, a fake sysfs root, a fake proc root, a
# home, a Steam library, an empty stub bin dir first on PATH, and an empty call log.
t_case() {
  T_NAME="$1"
  T_TMP="$(mktemp -d "$T_ROOT/case.XXXXXX")"
  LOG_DIR="$T_TMP/log"
  GS_SYSFS_ROOT="$T_TMP/sys"
  GS_PROC_ROOT="$T_TMP/proc"
  T_BIN="$T_TMP/bin"
  T_CALLS="$T_TMP/calls.log"
  mkdir -p "$LOG_DIR" "$GS_SYSFS_ROOT" "$GS_PROC_ROOT" "$T_BIN" \
    "$T_TMP/home" "$T_TMP/xdg" "$T_TMP/steam" "$T_TMP/steamlib"
  : > "$T_CALLS"
  PATH="$T_BIN:$T_PATH0"
  T_STDOUT=""
  T_STDERR=""
  T_RC=""
  export LOG_DIR GS_SYSFS_ROOT GS_PROC_ROOT T_TMP T_BIN T_CALLS
}

# t_stub NAME [BODY]
# Writes an executable stub NAME into $T_BIN. Each call appends one line to $T_CALLS:
# NAME followed by its arguments, each quoted with printf %q. BODY (bash, optional) runs
# after the record with the call's arguments in "$@"; without BODY the stub exits 0.
t_stub() {
  local name="$1" body="${2:-exit 0}"
  {
    printf '#!/usr/bin/env bash\n'
    printf '{ printf %%s %q; for a in "$@"; do printf " %%q" "$a"; done; printf "\\n"; } >> "$T_CALLS"\n' "$name"
    printf '%s\n' "$body"
  } > "$T_BIN/$name"
  chmod +x "$T_BIN/$name"
}

# t_calls NAME
# Prints the recorded calls of stub NAME, one per line, without the leading name.
t_calls() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "$1") echo "" ;;
      "$1 "*) echo "${line#"$1 "}" ;;
    esac
  done < "$T_CALLS"
}

# t_fake_gpu ADDR VENDOR DEVICE [CLASS] [RENDER]
# Creates a PCI function under $GS_SYSFS_ROOT/bus/pci/devices/ADDR with the vendor, device
# and class files the kernel writes (for example 0x1002, 0x1586, 0x038000), and, when
# RENDER is given (for example renderD128), a drm/RENDER directory. CLASS defaults to
# 0x030000 (VGA).
t_fake_gpu() {
  local addr="$1" vendor="$2" device="$3" class="${4:-0x030000}" render="${5:-}"
  local dir="$GS_SYSFS_ROOT/bus/pci/devices/$addr"
  mkdir -p "$dir"
  echo "$vendor" > "$dir/vendor"
  echo "$device" > "$dir/device"
  echo "$class" > "$dir/class"
  if [ -n "$render" ]; then
    mkdir -p "$dir/drm/$render"
  fi
}

# t_run [VAR=VALUE ...] -- SCRIPT
# Runs SCRIPT in a fresh bash with a clean environment: PATH (stubs first), HOME, TERM,
# LOG_DIR, GS_SYSFS_ROOT, GS_PROC_ROOT, XDG_RUNTIME_DIR, STEAM_HOME, STEAM_LIBRARY,
# GS_REPO, T_FIXTURES, T_TMP, T_BIN and T_CALLS, plus the VAR=VALUE pairs given.
# Sets T_STDOUT, T_STDERR (contents, trailing newlines trimmed) and T_RC.
t_run() {
  local -a extra=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    extra+=("$1")
    shift
  done
  if [ "${1:-}" != "--" ] || [ $# -lt 2 ]; then
    echo "t_run: usage: t_run [VAR=VALUE ...] -- SCRIPT" >&2
    return 2
  fi
  shift
  local script="$1"
  T_RC=0
  env -i \
    PATH="$PATH" HOME="$T_TMP/home" TERM=dumb \
    LOG_DIR="$LOG_DIR" GS_SYSFS_ROOT="$GS_SYSFS_ROOT" GS_PROC_ROOT="$GS_PROC_ROOT" \
    XDG_RUNTIME_DIR="$T_TMP/xdg" STEAM_HOME="$T_TMP/steam" STEAM_LIBRARY="$T_TMP/steamlib" \
    GS_REPO="$GS_REPO" T_FIXTURES="$T_FIXTURES" \
    T_TMP="$T_TMP" T_BIN="$T_BIN" T_CALLS="$T_CALLS" \
    "${extra[@]}" \
    bash -c "$script" > "$T_TMP/stdout" 2> "$T_TMP/stderr" || T_RC=$?
  T_STDOUT="$(cat "$T_TMP/stdout")"
  T_STDERR="$(cat "$T_TMP/stderr")"
}

_t_ok() {
  T_PASS=$((T_PASS + 1))
}

_t_bad() {
  T_FAIL=$((T_FAIL + 1))
  printf 'FAIL %s: %s: %s\n' "$T_FILE" "$T_NAME" "$1" >&2
  shift
  local line
  for line in "$@"; do
    printf '     %s\n' "$line" >&2
  done
}

# assert_eq EXPECTED ACTUAL MESSAGE
assert_eq() {
  if [ "$1" == "$2" ]; then _t_ok; else _t_bad "$3" "expected: [$1]" "actual:   [$2]"; fi
}

# assert_ne UNEXPECTED ACTUAL MESSAGE
assert_ne() {
  if [ "$1" != "$2" ]; then _t_ok; else _t_bad "$3" "did not expect: [$1]"; fi
}

# assert_contains HAYSTACK NEEDLE MESSAGE
assert_contains() {
  case "$1" in
    *"$2"*) _t_ok ;;
    *) _t_bad "$3" "missing: [$2]" "in:      [$1]" ;;
  esac
}

# assert_not_contains HAYSTACK NEEDLE MESSAGE
assert_not_contains() {
  case "$1" in
    *"$2"*) _t_bad "$3" "unexpected: [$2]" "in:         [$1]" ;;
    *) _t_ok ;;
  esac
}

# assert_match REGEX ACTUAL MESSAGE (bash =~, extended regex)
assert_match() {
  if [[ "$2" =~ $1 ]]; then _t_ok; else _t_bad "$3" "regex:  [$1]" "actual: [$2]"; fi
}

# assert_empty ACTUAL MESSAGE
assert_empty() {
  if [ -z "$1" ]; then _t_ok; else _t_bad "$2" "expected empty, got: [$1]"; fi
}

# assert_rc EXPECTED MESSAGE (compares with T_RC from the last t_run)
assert_rc() {
  if [ "$1" == "$T_RC" ]; then _t_ok; else _t_bad "$2" "expected rc $1, got $T_RC" "stderr: [$T_STDERR]"; fi
}

# assert_file_eq EXPECTED_FILE ACTUAL_FILE MESSAGE (byte-identical)
assert_file_eq() {
  if cmp -s "$1" "$2"; then
    _t_ok
  else
    _t_bad "$3" "files differ: $1 $2"
    diff -u "$1" "$2" >&2 || true
  fi
}

# assert_no_file PATH MESSAGE
assert_no_file() {
  if [ ! -e "$1" ]; then _t_ok; else _t_bad "$2" "unexpected file: $1"; fi
}

# t_done
# Prints the file's summary and exits 1 when any assertion failed (2 when none ran).
t_done() {
  printf '%s: %d passed, %d failed\n' "$T_FILE" "$T_PASS" "$T_FAIL"
  if [ "$T_FAIL" -gt 0 ]; then exit 1; fi
  if [ "$T_PASS" -eq 0 ]; then exit 2; fi
  exit 0
}
