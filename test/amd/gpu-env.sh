# S3-U3 and S3-U4: gs_gpu_env (S3-D6), plus the AMD XORG_CONFIG default (S3-D9 (1)). Each
# case sources src/lib/common.sh in a clean bash under set -uo pipefail, as the flows do,
# with fake GS_SYSFS_ROOT and GS_PROC_ROOT trees, and reads the environment that a child
# process of that shell inherits.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # the t_run scripts expand in the child shell
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

# The Radeon 8060S of f155ad35 (gfx1151, display class 0x0380), its HDMI audio function, a
# second AMD GPU (an RX 7900 XTX) and an NVIDIA GPU with its driver loaded.
igpu() { t_fake_gpu 0000:c6:00.0 0x1002 0x1586 0x038000 renderD128; }
igpu_audio() { t_fake_gpu 0000:c6:00.1 0x1002 0x1640 0x040300; }
dgpu() { t_fake_gpu 0000:03:00.0 0x1002 0x744c 0x030000 renderD129; }
nvgpu() { t_fake_gpu 0000:01:00.0 0x10de 0x2684 0x030000 renderD130; }
nvidia_driver() { mkdir -p "$GS_PROC_ROOT/driver/nvidia"; }
nv_node() { nvidia_driver; nvgpu; }

# gpu_env [VAR=VALUE ...]: the pairs are the pod env. Sources common.sh and saves the
# environment of a child process in $T_TMP/env.out.
gpu_env() {
  t_run "$@" -- 'set -uo pipefail
. "$GS_REPO/src/lib/common.sh"
env > "$T_TMP/env.out"'
}

# The names gs_gpu_env may export, then the ones it must never set (S3-D6).
GPU_VARS=(GS_GPU_VENDOR GS_GPU_PCI_ADDRESS GS_GPU_VENDOR_SOURCE GS_RENDER_NODE
  GS_RENDER_NODE_HINT VK_LOADER_DRIVERS_SELECT MESA_VK_DEVICE_SELECT MESA_VK_WSI_DEBUG
  VK_DRIVER_FILES VK_ICD_FILENAMES DRI_PRIME MESA_SHADER_CACHE_DIR
  __GLX_VENDOR_LIBRARY_NAME __EGL_VENDOR_LIBRARY_FILENAMES)

# gpu_vars: the NAME=VALUE lines of env.out for GPU_VARS, in that order, set names only.
gpu_vars() {
  local name line out=""
  for name in "${GPU_VARS[@]}"; do
    while IFS= read -r line; do
      case "$line" in "$name="*) out+="$line"$'\n' ;; esac
    done < "$T_TMP/env.out"
  done
  printf '%s' "${out%$'\n'}"
}

# env_of NAME: the value of NAME in env.out, or <unset>.
env_of() {
  local line
  while IFS= read -r line; do
    case "$line" in "$1="*) printf '%s' "${line#*=}"; return 0 ;; esac
  done < "$T_TMP/env.out"
  printf '<unset>'
}

# quiet LABEL: the run exited 0 and printed nothing (gs_gpu_env is silent).
quiet() {
  assert_rc 0 "$1: exit code"
  assert_empty "$T_STDOUT" "$1: stdout"
  assert_empty "$T_STDERR" "$1: stderr"
}

IGPU_ENV='GS_GPU_VENDOR=amd
GS_GPU_PCI_ADDRESS=0000:c6:00.0
GS_GPU_VENDOR_SOURCE=env
GS_RENDER_NODE=/dev/dri/renderD128
VK_LOADER_DRIVERS_SELECT=*radeon*
MESA_VK_DEVICE_SELECT=1002:1586!'

t_case "U3 (a): amd plus a valid address selects that device"
igpu
gpu_env GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:c6:00.0
quiet "(a)"
assert_eq "$IGPU_ENV" "$(gpu_vars)" "(a) exports"

t_case "U3 (b): nvidia exports nothing, even with an AMD GPU in sysfs"
nv_node
igpu
gpu_env GS_GPU_VENDOR=nvidia
quiet "(b)"
assert_eq "GS_GPU_VENDOR=nvidia" "$(gpu_vars)" "(b) exports"

t_case "U3 (c): unset with /proc/driver/nvidia exports nothing"
nvidia_driver
igpu
gpu_env
quiet "(c)"
assert_eq "" "$(gpu_vars)" "(c) exports"

t_case "U3 (c), rule 4: an NVIDIA display device stops self-detection"
nvgpu
igpu
gpu_env
quiet "(c) nvidia device"
assert_eq "" "$(gpu_vars)" "(c) nvidia device exports"

t_case "U3 (d): unset with one AMD GPU and its HDMI audio function selects the GPU"
igpu
igpu_audio
gpu_env
quiet "(d)"
assert_eq "${IGPU_ENV/=env/=self}" "$(gpu_vars)" "(d) exports"

t_case "U3 (e): unset with two AMD GPUs selects nothing"
igpu
dgpu
gpu_env
quiet "(e)"
assert_eq "" "$(gpu_vars)" "(e) exports"

t_case "U3 (f): an address with no vendor takes amd from sysfs"
igpu
gpu_env GS_GPU_PCI_ADDRESS=0000:c6:00.0
quiet "(f)"
assert_eq "${IGPU_ENV/=env/=pci}" "$(gpu_vars)" "(f) exports"

t_case "U3 (f), rule 3: an address of a non-AMD device exports nothing"
nv_node
gpu_env GS_GPU_PCI_ADDRESS=0000:01:00.0
quiet "(f) nvidia address"
assert_eq "GS_GPU_PCI_ADDRESS=0000:01:00.0" "$(gpu_vars)" "(f) nvidia address exports"

t_case "U3 (g): preset VK_LOADER_DRIVERS_SELECT and MESA_VK_DEVICE_SELECT are kept"
igpu
gpu_env GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:c6:00.0 'VK_LOADER_DRIVERS_SELECT=*' \
  MESA_VK_DEVICE_SELECT=1002:1586
quiet "(g)"
assert_eq '*' "$(env_of VK_LOADER_DRIVERS_SELECT)" "(g) the loader filter kill switch is kept"
assert_eq 1002:1586 "$(env_of MESA_VK_DEVICE_SELECT)" "(g) the preset device select is kept"
assert_eq /dev/dri/renderD128 "$(env_of GS_RENDER_NODE)" "(g) render node"

t_case "U3 (h): the address names one of two AMD GPUs"
igpu
dgpu
gpu_env GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:03:00.0
quiet "(h)"
assert_eq "GS_GPU_VENDOR=amd
GS_GPU_PCI_ADDRESS=0000:03:00.0
GS_GPU_VENDOR_SOURCE=env
GS_RENDER_NODE=/dev/dri/renderD129
VK_LOADER_DRIVERS_SELECT=*radeon*
MESA_VK_DEVICE_SELECT=1002:744c!" "$(gpu_vars)" "(h) exports"

t_case "U3 (i): a preset GS_RENDER_NODE is overwritten and kept as the hint"
igpu
gpu_env GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:c6:00.0 GS_RENDER_NODE=/dev/dri/renderD129
quiet "(i)"
assert_eq /dev/dri/renderD128 "$(env_of GS_RENDER_NODE)" "(i) the derived node"
assert_eq /dev/dri/renderD129 "$(env_of GS_RENDER_NODE_HINT)" "(i) the hint"

# (j) and the rest of rule 2: amd with an address that fails a check (uppercase, no domain,
# no sysfs entry, an NVIDIA device, an AMD device without a render node) exports no
# selection and does not self-detect the Radeon in sysfs. The uppercase name exists in this
# sysfs, so only the format check can refuse it.
for addr in 0000:C6:00.0 c6:00.0 0000:c7:00.0 0000:01:00.0 0000:c5:00.0; do
  t_case "U3 (j): amd with the address $addr selects nothing"
  igpu
  nvgpu
  t_fake_gpu 0000:C6:00.0 0x1002 0x1586 0x038000 renderD128
  t_fake_gpu 0000:c5:00.0 0x1002 0x1586 0x038000
  gpu_env GS_GPU_VENDOR=amd "GS_GPU_PCI_ADDRESS=$addr" GS_RENDER_NODE=/dev/dri/renderD128
  quiet "(j) $addr"
  assert_eq "GS_GPU_VENDOR=amd
GS_GPU_PCI_ADDRESS=$addr
GS_GPU_VENDOR_SOURCE=env
GS_RENDER_NODE_HINT=/dev/dri/renderD128
VK_LOADER_DRIVERS_SELECT=*radeon*" "$(gpu_vars)" "(j) $addr exports"
done

t_case "U3 (k): GS_GPU_VENDOR=AMD runs the NVIDIA path"
igpu
gpu_env GS_GPU_VENDOR=AMD GS_GPU_PCI_ADDRESS=0000:c6:00.0
quiet "(k)"
assert_eq "GS_GPU_VENDOR=AMD
GS_GPU_PCI_ADDRESS=0000:c6:00.0" "$(gpu_vars)" "(k) exports"

t_case "U3 (l): a child bash keeps the first shell's source and hint"
igpu
printf '%s\n' 'set -uo pipefail' '. "$GS_REPO/src/lib/common.sh"' 'env > "$T_TMP/env.out"' \
  > "$T_TMP/child.sh"
t_run GS_RENDER_NODE=renderD128 -- 'set -uo pipefail
. "$GS_REPO/src/lib/common.sh"
bash "$T_TMP/child.sh"'
quiet "(l)"
assert_eq "GS_GPU_VENDOR=amd
GS_GPU_PCI_ADDRESS=0000:c6:00.0
GS_GPU_VENDOR_SOURCE=self
GS_RENDER_NODE=/dev/dri/renderD128
GS_RENDER_NODE_HINT=renderD128
VK_LOADER_DRIVERS_SELECT=*radeon*
MESA_VK_DEVICE_SELECT=1002:1586!" "$(gpu_vars)" "(l) the child's exports"

t_case "U4: wsi_mode sw exports MESA_VK_WSI_DEBUG=sw on amd"
igpu
echo sw > "$LOG_DIR/wsi_mode"
gpu_env GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:c6:00.0
quiet "U4 amd"
assert_eq sw "$(env_of MESA_VK_WSI_DEBUG)" "U4 amd"

t_case "U4: wsi_mode hw exports no MESA_VK_WSI_DEBUG"
igpu
echo hw > "$LOG_DIR/wsi_mode"
gpu_env GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:c6:00.0
quiet "U4 hw"
assert_eq '<unset>' "$(env_of MESA_VK_WSI_DEBUG)" "U4 hw"

t_case "U4: nvidia ignores wsi_mode sw"
nv_node
echo sw > "$LOG_DIR/wsi_mode"
gpu_env GS_GPU_VENDOR=nvidia
quiet "U4 nvidia"
assert_eq '<unset>' "$(env_of MESA_VK_WSI_DEBUG)" "U4 nvidia"

t_case "U4: an unset vendor ignores wsi_mode sw"
nv_node
echo sw > "$LOG_DIR/wsi_mode"
gpu_env
quiet "U4 unset"
assert_eq '<unset>' "$(env_of MESA_VK_WSI_DEBUG)" "U4 unset"

t_case "U4: a preset MESA_VK_WSI_DEBUG wins over wsi_mode sw"
igpu
echo sw > "$LOG_DIR/wsi_mode"
gpu_env GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:c6:00.0 MESA_VK_WSI_DEBUG=noshm
quiet "U4 preset"
assert_eq noshm "$(env_of MESA_VK_WSI_DEBUG)" "U4 preset"

t_case "U4 and S3-E9: amd with a bad address still exports sw from wsi_mode"
igpu
echo sw > "$LOG_DIR/wsi_mode"
gpu_env GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:c7:00.0
quiet "U4 bad address"
assert_eq sw "$(env_of MESA_VK_WSI_DEBUG)" "U4 bad address"

# S3-D9 (1): on AMD an explicit XORG_CONFIG wins, then GS_DUMMY_CONFIG, then the coexist
# config of the size. NVIDIA and unset keep the dummy configs and ignore GS_DUMMY_CONFIG.
# xorg_case LABEL EXPECTED SETUP [VAR=VALUE ...]
xorg_case() {
  local label="$1" want="$2" setup="$3"
  shift 3
  t_case "XORG_CONFIG: $label"
  "$setup"
  gpu_env "$@"
  quiet "$label"
  assert_eq "$want" "$(env_of XORG_CONFIG)" "$label"
}
AMD_POD=(GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:c6:00.0)
xorg_case "amd at 1080p" xorg-coexist-1080p.conf igpu "${AMD_POD[@]}"
xorg_case "amd at 1440p" xorg-coexist-1440p.conf igpu "${AMD_POD[@]}" CS2_DISPLAY_RES=2560x1440
xorg_case "amd at an unknown size" xorg-coexist-1080p.conf igpu "${AMD_POD[@]}" \
  CS2_DISPLAY_RES=1280x720
xorg_case "amd with GS_DUMMY_CONFIG" xorg-mine.conf igpu "${AMD_POD[@]}" \
  GS_DUMMY_CONFIG=xorg-mine.conf
xorg_case "amd with XORG_CONFIG and GS_DUMMY_CONFIG" xorg-pod.conf igpu "${AMD_POD[@]}" \
  XORG_CONFIG=xorg-pod.conf GS_DUMMY_CONFIG=xorg-mine.conf
xorg_case "self-detected amd" xorg-coexist-1080p.conf igpu
xorg_case "nvidia with GS_DUMMY_CONFIG" xorg-dummy-1080p.conf nv_node GS_GPU_VENDOR=nvidia \
  GS_DUMMY_CONFIG=xorg-mine.conf
xorg_case "nvidia at 1440p" xorg-dummy-1440p.conf nv_node GS_GPU_VENDOR=nvidia \
  CS2_DISPLAY_RES=2560x1440
xorg_case "unset at 1440p" xorg-dummy-1440p.conf nv_node CS2_DISPLAY_RES=2560x1440

t_done
