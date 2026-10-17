# S3-U13: the NVIDIA identity of start_xorg, xorg_running, stop_xorg and shutdown_display.
# A fresh bash sources src/lib/common.sh and src/lib/xorg.sh under set -uo pipefail, as
# src/flows/setup-steam.sh does, with GS_GPU_VENDOR unset and set to nvidia and every X
# tool stubbed. The stub calls, the spawned argv, stdout, stderr and $LOG_DIR/display of
# both runs must match one golden captured on the base commit.
# The lifecycle and coexist-retry runs are U13 itself and exit 0. The fail-* and
# persistence-* runs pin the NVIDIA texts that S3-D12 makes vendor-aware on AMD (xorg.sh
# L77, L112, L130, L134, L234, L242), the L244 die and the vendor-neutral L205 die; a die
# exits 1 there, and the exit code is part of the golden. One AMD tier A run after the
# capture stop line is the control: it must exit 0 as well.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # the t_run scripts and stub bodies expand in the child shell
# shellcheck disable=SC2329  # u13_both runs the setup_* functions by name
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=lib/golden.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/golden.sh"

DASH="$(printf '\342\200\224')"

# How setup-steam.sh loads xorg.sh. stdin is never a terminal, so nohup in spawn_logged
# prints nothing. The EXIT trap waits for the background stubs, so their argv files are
# complete when a die ends the script.
U13_LIBS='exec </dev/null
set -uo pipefail
SCRIPT_TAG=setup-steam
. "$GS_REPO/src/lib/common.sh"
. "$LIB_DIR/xorg.sh"
trap wait EXIT'

# The four functions of U13, in pod order, each followed by its exit code.
U13_RUN='start_xorg; echo "rc start_xorg=$?"
xorg_running; echo "rc xorg_running=$?"
stop_xorg; echo "rc stop_xorg=$?"
shutdown_display; echo "rc shutdown_display=$?"'

# Shell functions that steer start_xorg into its failure paths. kill records its
# arguments (a PID as PID) and answers kill -0 from $T_TMP/xorg.alive. grep answers the
# 'no screens found' checks of the Xorg logs from $T_TMP/no-screens. rm records the Xorg
# log cleanup (xorg.sh L236) and clears that flag when $T_TMP/rm.clears exists.
U13_FAKES='kill() {
  local a out=kill
  for a in "$@"; do
    case "$a" in
      *[!0-9]*) out="$out $a" ;;
      *) out="$out PID" ;;
    esac
  done
  printf "%s\n" "$out" >> "$T_CALLS"
  if [ "$1" = -0 ]; then [ -e "$T_TMP/xorg.alive" ]; return; fi
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
    printf "%s\n" "rm $*" >> "$T_CALLS"
    if [ -e "$T_TMP/rm.clears" ]; then command rm -f "$T_TMP/no-screens"; fi
    return 0
  fi
  command rm "$@"
}'

# u13_stubs FAILS
# The X tool stubs. xdpyinfo fails its first FAILS calls, and every call once pkill has
# stopped Xorg; otherwise it answers and marks X up. pgrep sees Xorg while X is up and not
# stopped, and sees openbox from its second openbox call on. Xorg and openbox run in the
# background (spawn_logged), so they write their argv to their own files, never to the
# shared call log. weston and Xwayland are stubbed only to prove they are never called.
u13_stubs() {
  local s
  printf '%s\n' "$1" > "$T_TMP/xdpy.fail"
  t_stub xdpyinfo 'n=0
if [ -r "$T_TMP/xdpy.count" ]; then read -r n < "$T_TMP/xdpy.count"; fi
n=$((n + 1))
echo "$n" > "$T_TMP/xdpy.count"
read -r k < "$T_TMP/xdpy.fail"
if [ -e "$T_TMP/x.down" ] || [ "$n" -le "$k" ]; then exit 1; fi
: > "$T_TMP/x.up"'
  t_stub pgrep 'case "$*" in
  "-x Xorg") [ -e "$T_TMP/x.up" ] && [ ! -e "$T_TMP/x.down" ] ;;
  "-x openbox")
    if [ -e "$T_TMP/openbox.seen" ]; then exit 0; fi
    : > "$T_TMP/openbox.seen"
    exit 1 ;;
  *) exit 1 ;;
esac'
  t_stub pkill 'if [ "$*" = "-x Xorg" ]; then : > "$T_TMP/x.down"; fi'
  t_stub xhost
  t_stub xprop
  t_stub nvidia-smi
  t_stub sleep
  t_stub weston
  t_stub Xwayland
  for s in Xorg openbox; do
    cat > "$T_BIN/$s" <<STUB
#!/usr/bin/env bash
{ printf %s $s; for a in "\$@"; do printf ' %s' "\$a"; done; echo; } >> "\$T_TMP/spawn.$s"
STUB
    chmod +x "$T_BIN/$s"
  done
}

# u13_actual
# What a golden holds: the exit code, the stub calls in order, the spawned argv (sorted,
# since background stubs race), stdout, stderr and $LOG_DIR/display, with U+2014 written
# as @EMDASH@.
u13_actual() {
  local text spawned="" display=""
  if compgen -G "$T_TMP/spawn.*" >/dev/null; then
    spawned="$(LC_ALL=C sort "$T_TMP"/spawn.*)"
  fi
  if [ -r "$LOG_DIR/display" ]; then display="$(cat "$LOG_DIR/display")"; fi
  text="rc=$T_RC
--- calls
$(cat "$T_CALLS")
--- spawned
$spawned
--- stdout
$T_STDOUT
--- stderr
$T_STDERR
--- display
$display"
  printf '%s' "${text//"$DASH"/@EMDASH@}"
}

# u13_both KEY SETUP SCRIPT
# Runs SCRIPT with GS_GPU_VENDOR unset and with nvidia, each in a fresh case prepared by
# the function SETUP, compares both runs with the golden KEY and checks what U13 forbids.
u13_both() {
  local key="$1" setup="$2" script="$3" v
  local -a env
  for v in unset nvidia; do
    t_case "$key ($v)"
    "$setup"
    env=(HOSTNAME=gs-u13)
    if [ "$v" = nvidia ]; then env+=(GS_GPU_VENDOR=nvidia); fi
    t_run "${env[@]}" -- "$script"
    t_golden "$key" "$(u13_actual)"
    assert_not_contains "$T_STDERR" "unbound variable" "$key ($v): no unbound variable"
    assert_no_file "$LOG_DIR/display_tier" "$key ($v): no display_tier file"
    assert_empty "$(t_calls weston)" "$key ($v): no weston call"
    assert_empty "$(t_calls Xwayland)" "$key ($v): no Xwayland call"
  done
}

U13_ALL_ZERO='rc start_xorg=0
rc xorg_running=0
rc stop_xorg=0
rc shutdown_display=0'

setup_fresh() { u13_stubs 1; }
setup_already_up() { u13_stubs 0; : > "$T_TMP/x.up"; }
setup_coexist_retry() { u13_stubs 21; : > "$T_TMP/no-screens"; : > "$T_TMP/rm.clears"; }

golden_lifecycle() {
  u13_both lifecycle-fresh setup_fresh "$U13_LIBS
$U13_RUN"
  assert_rc 0 "fresh start exits 0"
  assert_contains "$T_STDOUT" "$U13_ALL_ZERO" "fresh start: every function exits 0"
  u13_both lifecycle-already-up setup_already_up "$U13_LIBS
$U13_RUN"
  assert_rc 0 "already up exits 0"
  assert_contains "$T_STDOUT" "$U13_ALL_ZERO" "already up: every function exits 0"
  u13_both coexist-retry setup_coexist_retry "$U13_LIBS
$U13_FAKES
$U13_RUN"
  assert_rc 0 "coexist retry exits 0"
  assert_contains "$T_STDOUT" "$U13_ALL_ZERO" "coexist retry: every function exits 0"
}

setup_wedge_sigkill() { u13_stubs 1000; : > "$T_TMP/xorg.alive"; }
setup_foreign_held() { u13_stubs 1000; }
setup_coexist_fail() { u13_stubs 1000; : > "$T_TMP/no-screens"; }
setup_all_fail() { u13_stubs 1000; }
setup_wedged_running() { u13_stubs 1000; : > "$T_TMP/x.up"; }

golden_failures() {
  u13_both fail-wedge-sigkill setup_wedge_sigkill "$U13_LIBS
$U13_FAKES
$U13_RUN"
  u13_both fail-foreign-held setup_foreign_held "$U13_LIBS
$U13_FAKES
_x_socket_bound() { [ \"\$1\" = 0 ]; }
GS_FOREIGN_X_WAIT=0
$U13_RUN"
  u13_both fail-coexist setup_coexist_fail "$U13_LIBS
$U13_FAKES
$U13_RUN"
  u13_both fail-all-displays setup_all_fail "$U13_LIBS
$U13_FAKES
$U13_RUN"
  u13_both fail-wedged-running setup_wedged_running "$U13_LIBS
$U13_FAKES
$U13_RUN"
}

setup_no_smi() { :; }
setup_smi_fails() { t_stub nvidia-smi 'exit 1'; }

golden_persistence() {
  u13_both persistence-no-smi setup_no_smi "$U13_LIBS
enable_gpu_persistence; echo \"rc=\$?\""
  u13_both persistence-smi-fails setup_smi_fails "$U13_LIBS
enable_gpu_persistence; echo \"rc=\$?\""
}

golden_lifecycle
golden_failures
golden_persistence
if t_capture_mode; then t_done; fi

# The AMD cases follow; they never run in capture mode.

t_case "amd tier A control: the four functions exit 0"
u13_stubs 1
t_fake_gpu 0000:c6:00.0 0x1002 0x1586 0x038000 renderD128
t_run HOSTNAME=gs-u13 GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:c6:00.0 -- "$U13_LIBS
$U13_RUN"
assert_rc 0 "amd control exits 0"
assert_contains "$T_STDOUT" "$U13_ALL_ZERO" "amd control: every function exits 0"
assert_not_contains "$T_STDERR" "unbound variable" "amd control: no unbound variable"

t_done
