# S3 change C10 (S3-D12, S3-E7): the AMD texts of src/lib/xorg.sh. A fresh bash sources
# src/lib/common.sh and src/lib/xorg.sh under set -uo pipefail, as src/flows/setup-steam.sh
# does, with GS_GPU_VENDOR=amd, this pod's GPU 0000:c6:00.0 in the fake sysfs and every X
# tool stubbed, so X starts on the AMD base display :20 with the coexist config. Each
# start_xorg failure path dies with its AMD text, which names the AMD GPU and gives no
# nvidia-modeset or systemctl advice, the coexist retry logs its AMD line, and
# enable_gpu_persistence says nothing and never runs nvidia-smi. The L205 die stays
# vendor-neutral. NVIDIA and no vendor keep every text byte for byte: the goldens of
# xorg-nvidia-identity.sh (S3-U13) pin them.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # the t_run scripts and stub bodies expand in the child shell
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

DASH="$(printf '\342\200\224')"
AMD_ADDR=0000:c6:00.0
AMD_ENV=(HOSTNAME=gs-texts GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS="$AMD_ADDR")

# The AMD texts as the pod log shows them, for the base display :20.
WEDGE="[setup-steam] ERROR: AMD GPU $AMD_ADDR: Xorg on :20 (X config xorg-coexist-1080p.conf) hung during startup and survived SIGKILL, so it is stuck in the kernel and the walk over :20..:29 stops at :20. Read /var/log/Xorg.20.log and the node's dmesg; the node likely needs a reboot."
WEDGE21="[setup-steam] ERROR: AMD GPU $AMD_ADDR: Xorg on :21 (X config xorg-coexist-1080p.conf) hung during startup and survived SIGKILL, so it is stuck in the kernel and the walk over :20..:29 stops at :21. Read /var/log/Xorg.21.log and the node's dmesg; the node likely needs a reboot."
FOREIGN_BOUND="[setup-steam] ERROR: AMD GPU $AMD_ADDR: another GPU Job on this node (a stream, demo, render or bake) still holds :20: its X server is bound but not answering after 0s. One GPU Job per node is the limit, so this pod does not start a second X server. Wait for that Job to end. If no GPU Job runs on this node, an X server outside the streamer pods holds :20: set GS_X_DISPLAY_BASE to move the scanned range :20..:29."
FOREIGN_OWNED="${FOREIGN_BOUND/bound but not answering/owned by another streamer pod}"
COEXIST_LOG="[setup-steam] xorg: AMD GPU $AMD_ADDR: no display in :20..:29 started with X config xorg-coexist-1080p.conf, and /var/log/Xorg.<n>.log reports 'no screens found' (those logs are cleared for the retry); retrying with offscreen dummy X (xorg-coexist-1080p.conf)"
E7="[setup-steam] ERROR: AMD GPU $AMD_ADDR: Xorg failed to start on every display in :20..:29 with X config xorg-coexist-1080p.conf. Read /var/log/Xorg.<n>.log for those displays. If other X servers hold that range, set GS_X_DISPLAY_BASE to scan another one."
# Baseline L205, vendor-neutral and unchanged on every vendor.
WEDGED_RUNNING="[setup-steam] ERROR: Xorg on :20 is present but unresponsive (>5s) $DASH GPU/DRM modeset wedge; the node is likely poisoned until reboot. Failing so the pod reschedules."

# How setup-steam.sh loads xorg.sh. stdin is never a terminal, so nohup in spawn_logged
# prints nothing, and the EXIT trap waits for the background Xorg and openbox stubs.
LIBS='exec </dev/null
set -uo pipefail
SCRIPT_TAG=setup-steam
. "$GS_REPO/src/lib/common.sh"
. "$LIB_DIR/xorg.sh"
trap wait EXIT'

RUN='start_xorg; echo "rc start_xorg=$?"'

# Shell functions that steer start_xorg into its failure paths, as in
# xorg-nvidia-identity.sh: kill -0 answers from $T_TMP/xorg.alive, the 'no screens found'
# checks of the Xorg logs answer from $T_TMP/no-screens, and the log cleanup before the
# dummy retry (baseline L236) clears that flag when $T_TMP/rm.clears exists.
FAKES='kill() {
  if [ "${1:-}" = -0 ]; then [ -e "$T_TMP/xorg.alive" ]; return; fi
  return 0
}
grep() {
  if [ "$#" -eq 3 ] && [ "$1" = -qs ] && [ "$2" = "no screens found" ]; then
    case "$3" in
      /var/log/Xorg.*.log) [ -e "$T_TMP/no-screens" ]; return ;;
    esac
  fi
  command grep "$@"
}
rm() {
  if [ "$*" = "-f /var/log/Xorg.*.log" ]; then
    if [ -e "$T_TMP/rm.clears" ]; then command rm -f "$T_TMP/no-screens"; fi
    return 0
  fi
  command rm "$@"
}'

# tx_case NAME FAILS SMI
# Starts the case NAME with this pod's GPU in the fake sysfs and the X tool stubs:
# xdpyinfo fails its first FAILS calls, then answers and marks X up; pgrep sees Xorg while
# X is up and openbox from its second call on; Xorg and openbox write their argv to
# $T_TMP/spawn.Xorg and $T_TMP/spawn.openbox. SMI yes adds an nvidia-smi stub that exits 0,
# fails one that exits 1, and no leaves nvidia-smi off PATH.
tx_case() {
  local s
  t_case "$1"
  printf '%s\n' "$2" > "$T_TMP/xdpy.fail"
  t_stub xdpyinfo 'n=0
if [ -r "$T_TMP/xdpy.count" ]; then read -r n < "$T_TMP/xdpy.count"; fi
n=$((n + 1))
echo "$n" > "$T_TMP/xdpy.count"
read -r k < "$T_TMP/xdpy.fail"
if [ "$n" -le "$k" ]; then exit 1; fi
: > "$T_TMP/x.up"'
  t_stub pgrep 'case "$*" in
  "-x Xorg") [ -e "$T_TMP/x.up" ] ;;
  "-x openbox")
    if [ -e "$T_TMP/openbox.seen" ]; then exit 0; fi
    : > "$T_TMP/openbox.seen"
    exit 1 ;;
  *) exit 1 ;;
esac'
  t_stub xhost
  t_stub xprop
  t_stub sleep
  case "$3" in
    yes) t_stub nvidia-smi ;;
    fails) t_stub nvidia-smi 'exit 1' ;;
  esac
  for s in Xorg openbox; do
    cat > "$T_BIN/$s" <<STUB
#!/usr/bin/env bash
echo "$s \$*" >> "\$T_TMP/spawn.$s"
STUB
    chmod +x "$T_BIN/$s"
  done
  t_fake_gpu "$AMD_ADDR" 0x1002 0x1586 0x038000 renderD128
}

# n_spawned: how many Xorg servers start_xorg started.
n_spawned() {
  if [ -e "$T_TMP/spawn.Xorg" ]; then wc -l < "$T_TMP/spawn.Xorg"; else echo 0; fi
}

# tx_clean LABEL: what no AMD run may print or call.
tx_clean() {
  assert_not_contains "$T_STDOUT$T_STDERR" "nvidia" "$1: no nvidia text"
  assert_not_contains "$T_STDOUT$T_STDERR" "systemctl" "$1: no systemctl advice"
  assert_empty "$(t_calls nvidia-smi)" "$1: no nvidia-smi call"
  assert_not_contains "$T_STDERR" "unbound variable" "$1: no unbound variable"
}

tx_run() {
  t_run "${AMD_ENV[@]}" "$@"
}

tx_case "wedge: Xorg on :20 survives SIGKILL" 1000 yes
: > "$T_TMP/xorg.alive"
tx_run -- "$LIBS
$FAKES
$RUN"
assert_rc 1 "wedge: start_xorg dies"
assert_eq "$WEDGE" "$T_STDERR" "wedge: stderr is the AMD wedge text alone"
assert_eq 1 "$(n_spawned)" "wedge: one Xorg, the walk stops at :20"
tx_clean "wedge"

tx_case "wedge on :21 after :20 answers: the text names :21 and the whole range" 1000 yes
t_stub xdpyinfo 'case "$*" in *"-display :20"*) exit 0 ;; esac
exit 1'
: > "$T_TMP/xorg.alive"
tx_run -- "$LIBS
$FAKES
$RUN"
assert_rc 1 "wedge :21: start_xorg dies"
assert_eq "$WEDGE21" "$T_STDERR" "wedge :21: stderr is the AMD wedge text for :21 alone"
assert_eq 1 "$(n_spawned)" "wedge :21: one Xorg, the walk skips :20 and stops at :21"
assert_contains "$(cat "$T_TMP/spawn.Xorg" 2>/dev/null)" "Xorg :21 -config xorg-coexist-1080p.conf" "wedge :21: that Xorg ran on :21 with the coexist config"
tx_clean "wedge :21"

tx_case "foreign X: :20 bound but not answering" 1000 yes
tx_run -- "$LIBS
$FAKES
_x_socket_bound() { [ \"\$1\" = 20 ]; }
GS_FOREIGN_X_WAIT=0
$RUN"
assert_rc 1 "foreign bound: start_xorg dies"
assert_eq "$FOREIGN_BOUND" "$T_STDERR" "foreign bound: stderr is the AMD foreign-X text alone"
assert_eq 0 "$(n_spawned)" "foreign bound: no Xorg started"
tx_clean "foreign bound"

tx_case "foreign X: :20 owned by another streamer pod" 0 yes
t_stub xprop 'echo "_GS_STREAMER(STRING) = \"gs-other\""'
tx_run -- "$LIBS
$FAKES
_x_socket_bound() { [ \"\$1\" = 20 ]; }
GS_FOREIGN_X_WAIT=0
$RUN"
assert_rc 1 "foreign owned: start_xorg dies"
assert_eq "$FOREIGN_OWNED" "$T_STDERR" "foreign owned: stderr is the AMD foreign-X text alone"
assert_eq 0 "$(n_spawned)" "foreign owned: no Xorg started"
tx_clean "foreign owned"

tx_case "coexist X fails on every display, 'no screens found': the E7 die" 1000 yes
: > "$T_TMP/no-screens"
tx_run -- "$LIBS
$FAKES
$RUN"
assert_rc 1 "coexist fail: start_xorg dies"
assert_contains "$T_STDOUT" "$COEXIST_LOG" "coexist fail: the AMD retry line"
assert_not_contains "$T_STDOUT" "GPU scanout unavailable" "coexist fail: no NVIDIA retry line"
assert_eq "$E7" "$T_STDERR" "coexist fail: stderr is the AMD E7 text alone"
assert_eq 20 "$(n_spawned)" "coexist fail: ten Xorg on :20..:29, ten more in the retry"
tx_clean "coexist fail"

tx_case "X fails on every display without 'no screens found': the same E7 die" 1000 yes
tx_run -- "$LIBS
$FAKES
$RUN"
assert_rc 1 "all fail: start_xorg dies"
assert_not_contains "$T_STDOUT" "retrying" "all fail: no retry"
assert_eq "$E7" "$T_STDERR" "all fail: stderr is the AMD E7 text alone"
assert_eq 10 "$(n_spawned)" "all fail: ten Xorg on :20..:29"
tx_clean "all fail"

tx_case "GS_X_DISPLAY_BASE=30: the E7 die names :30..:39" 1000 yes
tx_run GS_X_DISPLAY_BASE=30 -- "$LIBS
$FAKES
$RUN"
assert_rc 1 "base 30: start_xorg dies"
assert_eq "${E7//:20..:29/:30..:39}" "$T_STDERR" "base 30: the E7 text names :30..:39"
tx_clean "base 30"

tx_case "no GS_GPU_PCI_ADDRESS: the E7 die says (no address)" 1000 yes
t_run HOSTNAME=gs-texts GS_GPU_VENDOR=amd -- "$LIBS
$FAKES
$RUN"
assert_rc 1 "no address: start_xorg dies"
assert_eq "${E7/"AMD GPU $AMD_ADDR:"/AMD GPU (no address):}" "$T_STDERR" "no address: the E7 text says (no address)"
tx_clean "no address"

tx_case "coexist retry succeeds on :20" 21 yes
: > "$T_TMP/no-screens"
: > "$T_TMP/rm.clears"
tx_run -- "$LIBS
$FAKES
$RUN"
assert_rc 0 "coexist retry: exits 0"
assert_contains "$T_STDOUT" "$COEXIST_LOG" "coexist retry: the AMD retry line"
assert_contains "$T_STDOUT" "rc start_xorg=0" "coexist retry: start_xorg returns 0"
assert_not_contains "$T_STDOUT" "GPU scanout unavailable" "coexist retry: no NVIDIA retry line"
assert_empty "$T_STDERR" "coexist retry: empty stderr"
assert_eq ":20" "$(cat "$LOG_DIR/display" 2>/dev/null)" "coexist retry: display :20"
tx_clean "coexist retry"

tx_case "fresh start on :20 without nvidia-smi: nothing about persistence" 1 no
tx_run -- "$LIBS
$RUN"
assert_rc 0 "fresh: exits 0"
assert_contains "$T_STDOUT" "rc start_xorg=0" "fresh: start_xorg returns 0"
assert_not_contains "$T_STDOUT" "persistence" "fresh: no persistence line"
assert_empty "$T_STDERR" "fresh: empty stderr"
assert_eq ":20" "$(cat "$LOG_DIR/display" 2>/dev/null)" "fresh: display :20"
tx_clean "fresh"

for smi in no yes fails; do
  tx_case "enable_gpu_persistence, nvidia-smi $smi: silent" 0 "$smi"
  tx_run -- "$LIBS
enable_gpu_persistence; echo \"rc=\$?\""
  assert_rc 0 "persistence ($smi): exits 0"
  assert_eq "rc=0" "$T_STDOUT" "persistence ($smi): returns 0 and prints nothing"
  assert_empty "$T_STDERR" "persistence ($smi): empty stderr"
  tx_clean "persistence ($smi)"
done

tx_case "Xorg present but unresponsive: the vendor-neutral L205 die" 1000 yes
: > "$T_TMP/x.up"
tx_run -- "$LIBS
$FAKES
$RUN"
assert_rc 1 "L205: start_xorg dies"
assert_eq "$WEDGED_RUNNING" "$T_STDERR" "L205: the baseline text, unchanged on AMD"
assert_eq 0 "$(n_spawned)" "L205: no Xorg started"
tx_clean "L205"

t_done
