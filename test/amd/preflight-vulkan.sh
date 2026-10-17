# S3 changes C8 and C9, the preflight split (S3-D11), with errors S3-E4, E5, E8, E9 and
# E13. preflight_gpu keeps its skip, WSL and vulkaninfo-installed checks and no longer runs
# vulkaninfo. preflight_vulkan, which setup-steam.sh calls right after start_xorg, runs one
# timeout 30 vulkaninfo with stderr in $LOG_DIR/vulkaninfo.err and writes
# $LOG_DIR/gpu_identity. On AMD a failed check dies with a message that names the GPU
# address; on NVIDIA and with no vendor each finding is a WARN with today's text until
# S3-T19. vulkaninfo, vkcube, timeout and uname are stubs; the dumps come from lib/dumps.sh.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # the t_run scripts and stub bodies expand in the child shell
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=lib/dumps.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/dumps.sh"

# The texts kept from before the split hold U+2014, which no added line may contain.
DASH="$(printf '\342\200\224')"
AMD_ADDR=0000:c6:00.0
AMD_ENV=(GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS="$AMD_ADDR")
OK_LINE='[setup-steam] gpu preflight: ok (Vulkan WSI + hardware device present)'
RADV_NAME='Radeon 8060S Graphics (RADV GFX1151)'
AMD_LOG="[setup-steam] gpu preflight: AMD GPU $AMD_ADDR: '$RADV_NAME' (1002:1586), driver 'Mesa 25.2.8-0ubuntu0.24.04.2', render node /dev/dri/renderD128, source env"
RADV_KEYS="name=$RADV_NAME
vendor_id=0x1002
device_id=0x1586
driver_info=Mesa 25.2.8-0ubuntu0.24.04.2
pipeline_cache_uuid=a8b3c2d15e6f4a7b8c9d0e1f2a3b4c5d"
NV_ID='name=NVIDIA GeForce RTX 3060
vendor_id=0x10de
device_id=0x2504
driver_info=580.82.07
pipeline_cache_uuid=5b9e1a2c3d4f5061728394a5b6c7d8e9
pci_address=
render_node=
source=
wsi='
LIBS='set -uo pipefail
. "$GS_REPO/src/lib/common.sh"
. "$LIB_DIR/xorg.sh"
'

# amd_id [WSI] [TIER] [ADDR] [NODE]: the gpu_identity that preflight_vulkan writes for
# the radv dump on AMD.
amd_id() {
  printf '%s\n' "$RADV_KEYS" "pci_address=${3-$AMD_ADDR}" \
    "render_node=${4-/dev/dri/renderD128}" source=env "wsi=${1:-}" "display_tier=${2:-A}"
}

# vk_case NAME [DUMP_ARGS...]: starts a case. The vulkaninfo stub prints vk_dump DUMP_ARGS
# (nothing without them) and one line on stderr, and exits 1 when it printed nothing;
# vkcube exits with $VKCUBE_RC (default 0); timeout runs its command without a limit. The
# fake sysfs holds this pod's GPU, 0000:c6:00.0 (1002:1586, renderD128).
vk_case() {
  t_case "$1"
  shift
  : > "$T_TMP/vk.out"
  if [ $# -gt 0 ]; then vk_dump "$@" > "$T_TMP/vk.out"; fi
  t_stub vulkaninfo 'cat "$T_TMP/vk.out"; echo "vulkaninfo stub stderr" >&2; [ -s "$T_TMP/vk.out" ]'
  t_stub vkcube 'exit "${VKCUBE_RC:-0}"'
  t_stub timeout 'shift; exec "$@"'
  t_fake_gpu "$AMD_ADDR" 0x1002 0x1586 0x038000 renderD128
}

# nv_node: the NVIDIA driver is loaded, so gs_gpu_env never self-detects the AMD GPU.
nv_node() {
  mkdir -p "$GS_PROC_ROOT/driver/nvidia"
}

# min_path: $T_TMP/min with bash, grep, awk and tail only, for runs that must not find a
# vulkaninfo on PATH (the image itself ships one).
min_path() {
  local c
  mkdir -p "$T_TMP/min"
  for c in bash grep awk tail; do ln -s "$(command -v "$c")" "$T_TMP/min/$c"; done
}

# pv [VAR=VALUE ...]: sources common.sh and xorg.sh under set -uo pipefail, as
# setup-steam.sh does, and runs preflight_vulkan as the last command, so T_RC is its exit
# code.
pv() {
  t_run SCRIPT_TAG=setup-steam "$@" -- "$LIBS"'preflight_vulkan'
}

# n_calls NAME: how many calls the stub NAME recorded.
n_calls() {
  local line n=0
  while IFS= read -r line; do
    case "$line" in "$1"|"$1 "*) n=$((n + 1)) ;; esac
  done < "$T_CALLS"
  echo "$n"
}

# identity: the gpu_identity of the last run, or nothing.
identity() {
  cat "$LOG_DIR/gpu_identity" 2>/dev/null
}

vk_case "amd: a healthy radv device passes, logs it and writes gpu_identity" radv
pv "${AMD_ENV[@]}"
assert_rc 0 "exit code"
assert_eq "$AMD_LOG
$OK_LINE" "$T_STDOUT" "the device line, then the ok line"
assert_empty "$T_STDERR" "no WARN"
assert_eq "$(amd_id)" "$(identity)" "gpu_identity, display_tier A without a tier file"
assert_eq "30 vulkaninfo
20 vkcube --c 60" "$(t_calls timeout)" "one vulkaninfo run, then the tier A vkcube"
assert_eq 1 "$(n_calls vulkaninfo)" "vulkaninfo runs once"
assert_eq "vulkaninfo stub stderr" "$(cat "$LOG_DIR/vulkaninfo.err" 2>/dev/null)" \
  "vulkaninfo's stderr is in vulkaninfo.err"
assert_eq yes "$(if [ -e "$LOG_DIR/vkcube.log" ]; then echo yes; fi)" "vkcube.log is written"

vk_case "amd tier A with sw WSI: wsi=sw, vkcube runs" radv
echo sw > "$LOG_DIR/wsi_mode"
echo 'A default' > "$LOG_DIR/display_tier"
pv "${AMD_ENV[@]}"
assert_rc 0 "exit code"
assert_eq "$(amd_id sw A)" "$(identity)" "gpu_identity"
assert_eq 1 "$(n_calls vkcube)" "vkcube runs on tier A"

vk_case "amd tier C: display_tier=C and no vkcube (the self-test ran it)" radv
echo hw > "$LOG_DIR/wsi_mode"
echo 'C requested' > "$LOG_DIR/display_tier"
pv "${AMD_ENV[@]}"
assert_rc 0 "exit code"
assert_eq "$(amd_id hw C)" "$(identity)" "gpu_identity"
assert_eq 0 "$(n_calls vkcube)" "no vkcube on tier C"
assert_eq "$AMD_LOG
$OK_LINE" "$T_STDOUT" "the device line, then the ok line"
assert_empty "$T_STDERR" "no WARN"

vk_case "amd tier A after a tier C fallback: vkcube runs" radv
echo 'A fallback:no-dri3' > "$LOG_DIR/display_tier"
pv "${AMD_ENV[@]}"
assert_rc 0 "exit code"
assert_eq "$(amd_id '' A)" "$(identity)" "gpu_identity"
assert_eq 1 "$(n_calls vkcube)" "vkcube runs"

# addr_die ADDR CHECK: the last run died before vulkaninfo, naming ADDR and CHECK.
addr_die() {
  assert_rc 1 "exit code"
  assert_contains "$T_STDERR" \
    "[setup-steam] ERROR: AMD GPU address '$1' (GS_GPU_PCI_ADDRESS) failed the $2 check, so this pod has no usable GPU." \
    "the die names the address and the check"
  assert_eq 0 "$(n_calls timeout)" "no vulkaninfo run"
  assert_no_file "$LOG_DIR/gpu_identity" "no gpu_identity"
}

PRESENCE="presence (GS_GPU_PCI_ADDRESS is empty or unset)"
vk_case "amd with an empty address dies" radv
pv GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=
addr_die "" "$PRESENCE"

vk_case "amd with no address dies" radv
pv GS_GPU_VENDOR=amd
addr_die "" "$PRESENCE"

vk_case "amd with an uppercase address dies" radv
pv GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:C6:00.0
addr_die 0000:C6:00.0 "format (lowercase dddd:bb:dd.f with the domain)"

vk_case "amd with an address that has no sysfs entry dies" radv
pv GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:ff:00.0
addr_die 0000:ff:00.0 "sysfs entry ($GS_SYSFS_ROOT/bus/pci/devices/0000:ff:00.0)"

vk_case "amd with an NVIDIA address dies" radv
t_fake_gpu 0000:01:00.0 0x10de 0x2504 0x030000 renderD129
pv GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:01:00.0
addr_die 0000:01:00.0 "vendor 0x1002 (sysfs vendor 0x10de)"

vk_case "amd with an address that has no render node dies" radv
t_fake_gpu 0000:c7:00.0 0x1002 0x1586 0x038000
pv GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:c7:00.0
addr_die 0000:c7:00.0 "render node (no $GS_SYSFS_ROOT/bus/pci/devices/0000:c7:00.0/drm/renderD*)"

vk_case "amd: no vulkaninfo output after X dies with the vulkaninfo.err tail"
pv "${AMD_ENV[@]}"
assert_rc 1 "exit code"
assert_contains "$T_STDERR" \
  "[setup-steam] ERROR: AMD GPU $AMD_ADDR: vulkaninfo gave no usable output after X started" "AMD die"
assert_contains "$T_STDERR" "The last lines of $LOG_DIR/vulkaninfo.err: vulkaninfo stub stderr" \
  "the vulkaninfo.err tail"
assert_not_contains "$T_STDERR" "returned nothing usable" "not the NVIDIA WARN"
assert_no_file "$LOG_DIR/gpu_identity" "no device, so no gpu_identity"

vk_case "amd without vulkaninfo on PATH dies with the vulkaninfo.err tail" radv
rm "$T_BIN/vulkaninfo"
min_path
t_run SCRIPT_TAG=setup-steam "${AMD_ENV[@]}" -- "$LIBS"'PATH="$T_BIN:$T_TMP/min"
preflight_vulkan'
assert_rc 1 "exit code"
assert_contains "$T_STDERR" "vulkaninfo gave no usable output after X started" "AMD die"
assert_contains "$T_STDERR" "vulkaninfo: not found" "the tail names the missing command"

vk_case "amd: a missing VK_KHR_xlib_surface dies with an AMD text" -x VK_KHR_xlib_surface radv
pv "${AMD_ENV[@]}"
assert_rc 1 "exit code"
assert_contains "$T_STDERR" \
  "[setup-steam] ERROR: AMD GPU $AMD_ADDR: the Vulkan loader is missing WSI extension(s): VK_KHR_xlib_surface after X started" \
  "AMD die with the missing extension only"
assert_not_contains "$T_STDERR" NVIDIA "no NVIDIA advice"
assert_eq "$(amd_id)" "$(identity)" "gpu_identity is written before the checks"
assert_eq 0 "$(n_calls vkcube)" "no vkcube"

vk_case "amd: only a CPU device dies with an AMD text" lvp
pv "${AMD_ENV[@]}"
assert_rc 1 "exit code"
assert_contains "$T_STDERR" \
  "[setup-steam] ERROR: AMD GPU $AMD_ADDR: no hardware Vulkan device after X started" "AMD die"
assert_not_contains "$T_STDERR" NVIDIA "no NVIDIA advice"
assert_contains "$(identity)" "name=llvmpipe (LLVM 20.1.2, 256 bits)" "gpu_identity names the CPU device"

vk_case "amd: two devices after the filters die" radv radv
pv "${AMD_ENV[@]}"
assert_rc 1 "exit code"
assert_contains "$T_STDERR" \
  "[setup-steam] ERROR: AMD GPU $AMD_ADDR: vulkaninfo lists 2 devices after the filters (MESA_VK_DEVICE_SELECT='1002:1586!', VK_LOADER_DRIVERS_SELECT='*radeon*')" \
  "the die names the count and both filters"
assert_eq 0 "$(n_calls vkcube)" "no vkcube"

vk_case "amd: a Vulkan device id that differs from sysfs dies with both pairs" radv1587
pv "${AMD_ENV[@]}"
assert_rc 1 "exit code"
assert_contains "$T_STDERR" \
  "[setup-steam] ERROR: AMD GPU $AMD_ADDR: Vulkan reports vendor:device 1002:1587 ('$RADV_NAME') but sysfs has 1002:1586 for this address" \
  "both pairs"

vk_case "amd tier A: a failed vkcube dies" radv
pv "${AMD_ENV[@]}" VKCUBE_RC=1
assert_rc 1 "exit code"
assert_contains "$T_STDERR" \
  "[setup-steam] ERROR: AMD GPU $AMD_ADDR: the vkcube smoke test (timeout 20 vkcube --c 60 on DISPLAY :20) failed with exit 1" \
  "the die names the command, the display and the exit code"
assert_contains "$T_STDERR" "$LOG_DIR/vkcube.log" "the die points at vkcube.log"
assert_not_contains "$T_STDOUT" "gpu preflight: ok" "no ok line"

vk_case "amd: shader_abort WARNs and passes" abort
pv "${AMD_ENV[@]}"
assert_rc 0 "exit code"
assert_contains "$T_STDERR" \
  "[setup-steam] WARN: gpu preflight: AMD GPU $AMD_ADDR: vulkaninfo mentions shader_abort on 1 line(s)." \
  "the shader_abort WARN"
assert_contains "$T_STDOUT" "$OK_LINE" "the ok line"

vk_case "amd: another GPU with the same vendor:device WARNs" radv
t_fake_gpu 0000:c7:00.0 0x1002 0x1586 0x038000 renderD129
t_fake_gpu 0000:c6:00.1 0x1002 0x1640 0x040300
pv "${AMD_ENV[@]}"
assert_rc 0 "exit code"
assert_contains "$T_STDERR" \
  "[setup-steam] WARN: gpu preflight: AMD GPU $AMD_ADDR: another GPU on this node has the same vendor:device 1002:1586 (0000:c7:00.0)." \
  "the WARN names the other GPU"
assert_not_contains "$T_STDERR" "0000:c6:00.1" "the audio function is not a GPU"
assert_contains "$T_STDOUT" "$OK_LINE" "the ok line"

vk_case "amd found by self-detection WARNs" radv
pv
assert_rc 0 "exit code"
assert_contains "$T_STDERR" \
  "[setup-steam] WARN: gpu preflight: AMD GPU $AMD_ADDR was found by self-detection (GS_GPU_VENDOR_SOURCE=self)" \
  "the self WARN"
assert_contains "$(identity)" "source=self" "gpu_identity source"
assert_contains "$T_STDOUT" "$OK_LINE" "the ok line"

vk_case "amd: a GS_RENDER_NODE hint that names another node WARNs" radv
pv "${AMD_ENV[@]}" GS_RENDER_NODE=/dev/dri/renderD129
assert_rc 0 "exit code"
assert_contains "$T_STDERR" \
  "[setup-steam] WARN: gpu preflight: AMD GPU $AMD_ADDR: GS_RENDER_NODE from the pod env (/dev/dri/renderD129) differs from the render node derived from sysfs (/dev/dri/renderD128)" \
  "the hint WARN"
assert_contains "$T_STDOUT" "$OK_LINE" "the ok line"

vk_case "amd: a bare hint with the same basename is quiet" radv
pv "${AMD_ENV[@]}" GS_RENDER_NODE=renderD128
assert_rc 0 "exit code"
assert_empty "$T_STDERR" "no WARN"

for vendor in unset nvidia; do
  env=()
  if [ "$vendor" = nvidia ]; then env=(GS_GPU_VENDOR=nvidia); fi

  vk_case "$vendor: a healthy NVIDIA device passes with the ok line only" nv
  nv_node
  pv "${env[@]}"
  assert_rc 0 "$vendor exit code"
  assert_eq "$OK_LINE" "$T_STDOUT" "$vendor: the ok line"
  assert_empty "$T_STDERR" "$vendor: no WARN"
  assert_eq "$NV_ID" "$(identity)" "$vendor: gpu_identity without display_tier"
  assert_eq "30 vulkaninfo" "$(t_calls timeout)" "$vendor: one vulkaninfo run and no vkcube"
  assert_eq "vulkaninfo stub stderr" "$(cat "$LOG_DIR/vulkaninfo.err" 2>/dev/null)" \
    "$vendor: vulkaninfo.err"

  vk_case "$vendor: a missing VK_KHR_xlib_surface WARNs with today's text" \
    -x VK_KHR_xlib_surface nv
  nv_node
  pv "${env[@]}"
  assert_rc 0 "$vendor: a WARN, not a die, until S3-T19"
  assert_eq "[setup-steam] WARN: Vulkan loader on this node is missing WSI extension(s): VK_KHR_xlib_surface. cs2 can't create a swapchain and will segfault on renderer init (Steam logs 'BInit - Unable to initialize Vulkan'). Check the NVIDIA container runtime / ICD mounts on the node." \
    "$T_STDERR" "$vendor: the xorg.sh L170 text"
  assert_empty "$T_STDOUT" "$vendor: no ok line"

  vk_case "$vendor: only a CPU device WARNs with today's text" lvp
  nv_node
  pv "${env[@]}"
  assert_rc 0 "$vendor exit code"
  assert_eq "[setup-steam] WARN: no hardware Vulkan device on this node (only software rasterizer, if any) $DASH the NVIDIA ICD isn't reaching the pod. Check NVIDIA_DRIVER_CAPABILITIES and the container runtime." \
    "$T_STDERR" "$vendor: the xorg.sh L175 text"
  assert_empty "$T_STDOUT" "$vendor: no ok line"

  vk_case "$vendor: no vulkaninfo output WARNs with today's text"
  nv_node
  pv "${env[@]}"
  assert_rc 0 "$vendor exit code"
  assert_eq "[setup-steam] WARN: gpu preflight: vulkaninfo returned nothing usable $DASH skipping Vulkan checks" \
    "$T_STDERR" "$vendor: the xorg.sh L162 text"
  assert_empty "$T_STDOUT" "$vendor: no ok line"
  assert_no_file "$LOG_DIR/gpu_identity" "$vendor: no gpu_identity"

  vk_case "$vendor: a vendorID that is neither NVIDIA nor AMD WARNs" intel
  nv_node
  pv "${env[@]}"
  assert_rc 0 "$vendor exit code"
  assert_eq "[setup-steam] WARN: gpu preflight: the Vulkan device 'Intel(R) UHD Graphics 770 (ADL-S GT1)' has vendorID 0x8086, neither NVIDIA (0x10de) nor AMD (0x1002)" \
    "$T_STDERR" "$vendor: the vendorID WARN"
  assert_empty "$T_STDOUT" "$vendor: no ok line"
done

for v in intel AMD; do
  vk_case "GS_GPU_VENDOR=$v WARNs and runs the NVIDIA path" nv
  nv_node
  pv GS_GPU_VENDOR="$v"
  assert_rc 0 "$v exit code"
  assert_eq "[setup-steam] WARN: gpu preflight: GS_GPU_VENDOR='$v' is neither amd nor nvidia; running the NVIDIA path" \
    "$T_STDERR" "$v: the S3-E13 WARN"
  assert_eq "$OK_LINE" "$T_STDOUT" "$v: the ok line"
done

for v in 1 on true yes; do
  vk_case "amd with GS_SKIP_GPU_PREFLIGHT=$v writes gpu_identity only" radv
  pv "${AMD_ENV[@]}" GS_SKIP_GPU_PREFLIGHT="$v"
  assert_rc 0 "$v exit code"
  assert_empty "$T_STDOUT$T_STDERR" "$v: silent"
  assert_eq "$(amd_id)" "$(identity)" "$v: gpu_identity"
  assert_eq "30 vulkaninfo" "$(t_calls timeout)" "$v: no vkcube"
done

vk_case "amd skip: a wrong address does not die" radv
pv GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:ff:00.0 GS_SKIP_GPU_PREFLIGHT=1
assert_rc 0 "exit code"
assert_eq "$(amd_id '' A 0000:ff:00.0 '')" "$(identity)" "gpu_identity, best effort"

vk_case "nvidia skip: no vulkaninfo run and no gpu_identity" nv
nv_node
pv GS_SKIP_GPU_PREFLIGHT=1
assert_rc 0 "exit code"
assert_empty "$T_STDOUT$T_STDERR" "silent"
assert_eq 0 "$(n_calls timeout)" "no vulkaninfo run"
assert_no_file "$LOG_DIR/gpu_identity" "no gpu_identity"

vk_case "nvidia without vulkaninfo on PATH returns quietly" nv
nv_node
rm "$T_BIN/vulkaninfo"
min_path
t_run SCRIPT_TAG=setup-steam -- "$LIBS"'PATH="$T_BIN:$T_TMP/min"
preflight_vulkan'
assert_rc 0 "exit code"
assert_empty "$T_STDOUT$T_STDERR" "silent: preflight_gpu already warned"
assert_eq 0 "$(n_calls timeout)" "no vulkaninfo run"

# gpu_case NAME KERNEL: starts a preflight_gpu case; uname -r prints KERNEL.
gpu_case() {
  vk_case "$1" radv
  t_stub uname "echo $2"
}

for vendor in unset amd; do
  env=()
  if [ "$vendor" = amd ]; then env=("${AMD_ENV[@]}"); fi
  gpu_case "$vendor: preflight_gpu no longer runs vulkaninfo" 6.8.0-45-generic
  t_run SCRIPT_TAG=setup-steam "${env[@]}" -- "$LIBS"'preflight_gpu'
  assert_rc 0 "$vendor exit code"
  assert_empty "$T_STDOUT$T_STDERR" "$vendor: silent"
  assert_eq 0 "$(n_calls vulkaninfo)" "$vendor: no vulkaninfo call"
  assert_eq "-r" "$(t_calls uname)" "$vendor: the WSL check still runs"
done

gpu_case "preflight_gpu with GS_SKIP_GPU_PREFLIGHT=1 logs the skip" 6.8.0-45-generic
t_run SCRIPT_TAG=setup-steam GS_SKIP_GPU_PREFLIGHT=1 -- "$LIBS"'preflight_gpu'
assert_rc 0 "exit code"
assert_eq "[setup-steam] gpu preflight: skipped (GS_SKIP_GPU_PREFLIGHT)" "$T_STDOUT" "the skip line"
assert_eq 0 "$(n_calls uname)" "no WSL check"

gpu_case "preflight_gpu without vulkaninfo on PATH WARNs" 6.8.0-45-generic
rm "$T_BIN/vulkaninfo"
min_path
t_run SCRIPT_TAG=setup-steam -- "$LIBS"'PATH="$T_BIN:$T_TMP/min"
preflight_gpu'
assert_rc 0 "exit code"
assert_eq "[setup-steam] WARN: gpu preflight: vulkaninfo not installed $DASH skipping Vulkan checks" \
  "$T_STDERR" "the kept WARN"

gpu_case "preflight_gpu on a WSL2 kernel dies as before" 5.15.153.1-microsoft-standard-WSL2
t_run SCRIPT_TAG=setup-steam -- "$LIBS"'preflight_gpu'
assert_rc 1 "exit code"
assert_eq "[setup-steam] ERROR: node is WSL2 (kernel '5.15.153.1-microsoft-standard-WSL2') $DASH the GPU has no DRM scanout and no Vulkan WSI, so cs2 segfaults on renderer init. Keep game-streamer pods off this node (taint / nodeSelector), or set GS_SKIP_GPU_PREFLIGHT=1 to try anyway." \
  "$T_STDERR" "the kept die"

t_case "setup-steam.sh calls preflight_vulkan once, right after start_xorg (S3 C9)"
count=0 after="" prev="" gpu_first=no seen_xorg=no
while IFS= read -r line; do
  case "$line" in
    preflight_vulkan) count=$((count + 1)); after="$prev" ;;
    preflight_gpu) if [ "$seen_xorg" = no ]; then gpu_first=yes; fi ;;
    start_xorg) seen_xorg=yes ;;
  esac
  prev="$line"
done < "$GS_REPO/src/flows/setup-steam.sh"
assert_eq 1 "$count" "one preflight_vulkan call"
assert_eq start_xorg "$after" "the line before it is start_xorg"
assert_eq yes "$gpu_first" "preflight_gpu still runs before start_xorg"

t_done
