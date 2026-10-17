# S3-U6: the AMD base display block of common.sh (S3-D21, S3-E15). Each case sources
# src/lib/common.sh in a clean bash with a temp LOG_DIR, under set -uo pipefail as the
# flows do, and prints DISPLAY twice: the shell's value and the value a child process
# inherits.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # the t_run scripts expand in the child shell
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ADDR=0000:c6:00.0

# display [VAR=VALUE ...]: sources common.sh with the pairs given and prints
# "<DISPLAY> <DISPLAY as a child sees it>".
display() {
  t_run "$@" -- 'set -uo pipefail
. "$GS_REPO/src/lib/common.sh"
printf "%s %s" "$DISPLAY" "$(printenv DISPLAY)"'
}

# amd [VAR=VALUE ...]: an AMD pod as the api starts it, vendor amd and the address of a
# fake Radeon 8060S; later pairs win.
amd() {
  t_fake_gpu "$ADDR" 0x1002 0x1586 0x038000 renderD128
  display GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS="$ADDR" "$@"
}

# display_is LABEL EXPECTED: the last run exited 0, printed EXPECTED for both values and
# was silent on stderr.
display_is() {
  assert_rc 0 "$1: exit code"
  assert_eq "$2 $2" "$T_STDOUT" "$1: DISPLAY"
  assert_empty "$T_STDERR" "$1: stderr"
}

# The seven U6 cases, in the order of the spec's pass line.
t_case "U6: vendor unset"
display
display_is "unset" :0

t_case "U6: amd"
amd
display_is "amd" :20

t_case "U6: amd with GS_X_DISPLAY_BASE=30"
amd GS_X_DISPLAY_BASE=30
display_is "base 30" :30

t_case "U6: amd with \$LOG_DIR/display holding :22"
printf '%s' :22 > "$LOG_DIR/display"
amd
display_is "display file" :22

t_case "U6: nvidia"
display GS_GPU_VENDOR=nvidia
display_is "nvidia" :0

t_case "U6: amd with GS_X_DISPLAY_BASE=x"
amd GS_X_DISPLAY_BASE=x
display_is "base x" :20

t_case "U6: amd with an inherited DISPLAY=:0"
amd DISPLAY=:0
display_is "inherited :0" :20

# Beyond U6.
t_case "amd: the display file wins over GS_X_DISPLAY_BASE and an inherited DISPLAY"
printf '%s' :22 > "$LOG_DIR/display"
amd GS_X_DISPLAY_BASE=30 DISPLAY=:5
display_is "file over base" :22

t_case "amd: an empty, negative or spaced GS_X_DISPLAY_BASE falls back to 20"
for base in '' -1 '2 0' 2x; do
  amd GS_X_DISPLAY_BASE="$base"
  display_is "base [$base]" :20
done

t_case "amd: any inherited DISPLAY is ignored before X"
amd DISPLAY=:5
display_is "inherited :5" :20

t_case "nvidia and unset keep an inherited DISPLAY and ignore GS_X_DISPLAY_BASE"
display GS_GPU_VENDOR=nvidia DISPLAY=:5 GS_X_DISPLAY_BASE=30
display_is "nvidia inherited" :5
display DISPLAY=:5 GS_X_DISPLAY_BASE=30
display_is "unset inherited" :5

t_case "unset vendor on a node with one AMD GPU and no NVIDIA driver (self-detection)"
t_fake_gpu "$ADDR" 0x1002 0x1586 0x038000 renderD128
display
display_is "self" :20

t_done
