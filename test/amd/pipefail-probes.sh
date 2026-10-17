# S3-U16: the shipped probes under set -euo pipefail (S3-D31). Each probe runs RUNS times in
# one bash against real-shaped dumps of about 237 KB (lib/dumps.sh), past the size from
# which a pipe into grep -q reads a present pattern as missing on every run. Every positive
# fixture must match and every negative fixture must miss on all runs, with the same
# gpu_identity each time. A static check then scans src/lib/xorg.sh for a pipe into an
# early-exit reader (grep -q, grep -m, head, sed with q, awk with exit).
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # the t_run scripts expand in the child shell
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=lib/dumps.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/dumps.sh"

RUNS=50
AMD_ADDR=0000:c6:00.0
OK_LINE='gpu preflight: ok (Vulkan WSI + hardware device present)'

# The loop each case runs in one fresh bash: RUNS calls of preflight_vulkan, each in a
# subshell with set -e, against the dump in $T_TMP/vk.out. Each run appends one line to
# $T_TMP/runs.txt: its exit code, whether its output holds the text in $T_TMP/expect.txt,
# and whether gpu_identity is the one in $T_TMP/id.expected, another one, or missing.
PV_LOOP='set -euo pipefail
. "$GS_REPO/src/lib/common.sh"
. "$LIB_DIR/xorg.sh"
VK=$(<"$T_TMP/vk.out")
EXPECT=$(<"$T_TMP/expect.txt")
EXP_ID=$(<"$T_TMP/id.expected")
timeout() { shift; "$@"; }
vulkaninfo() { printf "%s\n" "$VK"; }
vkcube() { :; }
for ((i = 0; i < RUNS; i++)); do
  rm -f "$LOG_DIR/gpu_identity"
  set +e
  ( set -e; preflight_vulkan ) > "$T_TMP/run.out" 2>&1
  rc=$?
  set -e
  text=no
  if grep -qF -- "$EXPECT" "$T_TMP/run.out"; then text=yes; fi
  id=none
  if [ -e "$LOG_DIR/gpu_identity" ]; then
    id=other
    if [ "$(<"$LOG_DIR/gpu_identity")" = "$EXP_ID" ]; then id=expected; fi
  fi
  printf "rc=%s text=%s id=%s\n" "$rc" "$text" "$id" >> "$T_TMP/runs.txt"
done'

# vk_identity DEVICE [AMD]: the gpu_identity that preflight_vulkan writes for a one-device
# dump of DEVICE; with AMD, the one for this pod's GPU on AMD at tier A.
vk_identity() {
  _vk_dev "$1"
  local uuid="${_VD_UUID//-/}"
  printf '%s\n' "name=$_VD_NAME" "vendor_id=$_VD_VID" "device_id=$_VD_DID" \
    "driver_info=$_VD_INFO" "pipeline_cache_uuid=${uuid,,}"
  if [ -n "${2:-}" ]; then
    printf '%s\n' "pci_address=$AMD_ADDR" render_node=/dev/dri/renderD128 source=env wsi= \
      display_tier=A
  else
    printf '%s\n' pci_address= render_node= source= wsi=
  fi
}

# pv_runs VENDOR TEXT RC DUMP_ARGS...: starts a case, then runs PV_LOOP on vk_dump
# DUMP_ARGS. VENDOR amd runs it for this pod's GPU, 0000:c6:00.0 in the fake sysfs; VENDOR
# unset runs it with no GPU variables, on a node with the NVIDIA driver loaded. Every run
# must exit RC, print TEXT and write the gpu_identity of the dump's first device.
pv_runs() {
  local vendor="$1" text="$2" rc="$3" dev
  shift 3
  t_case "$vendor $*: $RUNS runs exit $rc with '$text'"
  vk_dump "$@" > "$T_TMP/vk.out"
  printf '%s\n' "$text" > "$T_TMP/expect.txt"
  : > "$T_TMP/runs.txt"
  dev="${*: -1}"
  if [ "$vendor" = amd ]; then
    t_fake_gpu "$AMD_ADDR" 0x1002 0x1586 0x038000 renderD128
    vk_identity "$dev" amd > "$T_TMP/id.expected"
    t_run RUNS="$RUNS" SCRIPT_TAG=setup-steam GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS="$AMD_ADDR" \
      -- "$PV_LOOP"
  else
    mkdir -p "$GS_PROC_ROOT/driver/nvidia"
    vk_identity "$dev" > "$T_TMP/id.expected"
    t_run RUNS="$RUNS" SCRIPT_TAG=setup-steam -- "$PV_LOOP"
  fi
  assert_rc 0 "the loop runs to the end"
  assert_eq "$RUNS rc=$rc text=yes id=expected" \
    "$(sort "$T_TMP/runs.txt" | uniq -c | awk '{ $1 = $1; print }')" "every run"
}

t_case "control: a pipe of the radv dump into grep -q misses on every run"
vk_dump radv > "$T_TMP/vk.out"
t_run RUNS="$RUNS" -- 'set -uo pipefail
VK=$(<"$T_TMP/vk.out")
misses=0
for ((i = 0; i < RUNS; i++)); do
  if ! printf "%s\n" "$VK" | grep -q "Instance Extensions"; then misses=$((misses + 1)); fi
done
echo "misses=$misses"'
assert_eq "misses=$RUNS" "$T_STDOUT" "the baseline form of src/lib/xorg.sh L161 on this dump"

# Positive fixtures: every check passes.
pv_runs amd "$OK_LINE" 0 radv
pv_runs unset "$OK_LINE" 0 nv
# One negative fixture per check: the Instance Extensions heading (L161), an instance
# extension (L168) or the hardware device (L174) removed. The checks are the same lines on
# every vendor, and on AMD a miss is a die with its own text, so the negatives run on AMD.
pv_runs amd "vulkaninfo gave no usable output after X started" 1 -n radv
pv_runs amd "missing WSI extension(s): VK_KHR_xlib_surface after X started" 1 \
  -x VK_KHR_xlib_surface radv
pv_runs amd "no hardware Vulkan device after X started" 1 lvp

# The static check. PIPE_RE finds a pipe into grep with -q, -m, --quiet, --silent or
# --max-count, into head, into sed with a q, or into awk with exit. PIPE_ALLOW holds the
# untouched lines of src/lib/xorg.sh that do so: L106 and L151 pipe one short string, and
# L308, L364 and L395 only list windows for the log. Comment lines are skipped.
PIPE_RE='(^|[^|])\|[[:space:]]*(grep[^|]*[[:space:]](-[a-zA-Z]*[qm]|--quiet|--silent|--max-count)|head|sed[^|]*q|awk[^|]*exit)'
mapfile -t PIPE_ALLOW <<'EOF'
      if timeout 5 xprop -display ":$n" -root _GS_STREAMER 2>/dev/null | grep -q '='; then
  if [ -e /dev/dxg ] || printf '%s' "$kern" | grep -qi 'microsoft\|wsl'; then
      | head -25
  friends_id=$(xdotool search --name '^Friends List$' 2>/dev/null | head -1)
  wid=$(wmctrl -lx 2>/dev/null | awk '$3=="steamwebhelper.steam" && $NF=="Steam"{print $1; exit}')
EOF

# scan_pipes FILE: prints each line of FILE that PIPE_RE finds and PIPE_ALLOW does not hold,
# as path:line: text.
scan_pipes() {
  local line n=0 a ok
  while IFS= read -r line; do
    n=$((n + 1))
    case "${line#"${line%%[![:space:]]*}"}" in '#'*) continue ;; esac
    [[ "$line" =~ $PIPE_RE ]] || continue
    ok=no
    for a in "${PIPE_ALLOW[@]}"; do
      if [ "$line" = "$a" ]; then ok=yes; break; fi
    done
    if [ "$ok" = no ]; then printf '%s:%d: %s\n' "${1#"$GS_REPO"/}" "$n" "$line"; fi
  done < "$1"
}

t_case "static: src/lib/xorg.sh pipes into no early-exit reader outside the allowed lines"
assert_empty "$(scan_pipes "$GS_REPO/src/lib/xorg.sh")" "src/lib/xorg.sh"

# The C7 DRI3 probe (S3-D9) under the same rules. The control is the form S3-D9 forbids: a
# pipe of the xdpyinfo dump into grep -q misses DRI3 on every run.
t_case "control: a pipe of the xdpyinfo dump into grep -q misses DRI3 on every run"
xdpy_dump > "$T_TMP/xd.out"
t_run RUNS="$RUNS" -- 'set -uo pipefail
XD=$(<"$T_TMP/xd.out")
misses=0
for ((i = 0; i < RUNS; i++)); do
  if ! printf "%s\n" "$XD" | grep -q DRI3; then misses=$((misses + 1)); fi
done
echo "misses=$misses"'
assert_eq "misses=$RUNS" "$T_STDOUT" "the pipe form that S3-D9 forbids, on this dump"

# The loop each probe case runs in one fresh bash: RUNS calls of _xorg_wsi_probe on tier A,
# each in a subshell with set -e, against the dump in $T_TMP/xd.out. Each run appends its
# exit code and the wsi_mode it wrote (none when it wrote nothing) to $T_TMP/runs.txt.
WSI_LOOP='set -euo pipefail
. "$GS_REPO/src/lib/common.sh"
. "$LIB_DIR/xorg.sh"
XD=$(<"$T_TMP/xd.out")
timeout() { shift; "$@"; }
xdpyinfo() { printf "%s\n" "$XD"; }
for ((i = 0; i < RUNS; i++)); do
  rm -f "$LOG_DIR/wsi_mode"
  set +e
  ( set -e; _xorg_wsi_probe ) > "$T_TMP/run.out" 2>&1
  rc=$?
  set -e
  mode=none
  if [ -e "$LOG_DIR/wsi_mode" ]; then mode=$(<"$LOG_DIR/wsi_mode"); fi
  printf "rc=%s mode=%s\n" "$rc" "$mode" >> "$T_TMP/runs.txt"
done'

# wsi_runs NAME MODE [DUMP_ARGS...]: starts the case NAME, then runs WSI_LOOP for this pod's
# GPU, 0000:c6:00.0 in the fake sysfs, against xdpy_dump DUMP_ARGS. Every run must exit 0
# and write MODE.
wsi_runs() {
  local name="$1" mode="$2"
  shift 2
  t_case "amd DRI3 probe, $name: $RUNS runs exit 0 and write wsi_mode $mode"
  xdpy_dump "$@" > "$T_TMP/xd.out"
  : > "$T_TMP/runs.txt"
  t_fake_gpu "$AMD_ADDR" 0x1002 0x1586 0x038000 renderD128
  t_run RUNS="$RUNS" SCRIPT_TAG=setup-steam GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS="$AMD_ADDR" \
    -- "$WSI_LOOP"
  assert_rc 0 "the loop runs to the end"
  assert_eq "$RUNS rc=0 mode=$mode" \
    "$(sort "$T_TMP/runs.txt" | uniq -c | awk '{ $1 = $1; print }')" "every run"
}

# The positive fixture lists DRI3; the negative fixture is the same dump without it.
wsi_runs "DRI3 listed" hw
wsi_runs "DRI3 removed" sw -x DRI3

# The S3-D26 self-test parser runs and the scan of the tier C files go above this line.

# S3-U16 tier C extension: every shipped self-test parser sees oversized output.
# shellcheck source=lib/tierc-test-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/tierc-test-fixtures.sh"
for spec in 'good 0 none' 'no-dri3 1 no-dri3' 'root 1 root-size' 'vk-cpu 1 vkcube-failed'; do
  read -r mode expected_rc expected_reason <<< "$spec"
  [ "$expected_reason" != none ] || expected_reason=''
  selftest_case "S3-U16 tier C parser, $mode: fifty loops"
  t_stub xrandr 'echo "1920x1080 60.0*"; awk '\''BEGIN{for(i=0;i<6000;i++)print "padding randr line"}'\'''
  t_stub vkcube 'if [ "${SELF_MODE:-}" = vk-cpu ]; then
  echo "Selected GPU: llvmpipe (RADV test fixture), type: Cpu"
else
  echo "Selected GPU: AMD Radeon (RADV GFX1151), type: IntegratedGpu"
fi
awk '\''BEGIN{for(i=0;i<6000;i++)print "padding vulkan line"}'\'''
  BIG_PROBE=1 xdpyinfo -queryExtensions > "$T_TMP/large-xdpyinfo"
  bytes=$(wc -c < "$T_TMP/large-xdpyinfo")
  if [ "$bytes" -gt 65536 ]; then _t_ok; else _t_bad 'fixture must exceed 64 KB'; fi
  printf 'S3-U16 tier C: %s\n' "$mode"
  selftest_run SELF_MODE="$mode" BIG_PROBE=1 SELF_LOOPS=50 \
    SELF_EXPECT_RC="$expected_rc" SELF_EXPECT_REASON="$expected_reason"
  assert_rc 0 'all fifty results agree under pipefail'
  assert_contains "$T_STDOUT" 'loops=50 passed' 'no false positive or negative'
done
t_done
