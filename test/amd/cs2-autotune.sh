# The cs2_autotune half of S3-U5 and S3-E10: cs2_autotune (src/lib/cs2-tune.sh). The NVIDIA
# and unset outputs are goldens captured on the upstream commit; the AMD cases after the
# capture-mode line check the S3-D14 branch of S3 C13 (the name from gpu_identity, the mid
# tier, no clock lock, and the sw WSI frame cap through gs_sw_fps_clamp).
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # the t_run script and the stub bodies expand in the child shell
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=lib/golden.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/golden.sh"

DASH="$(printf '\342\200\224')"

# cs2_autotune the way run-live.sh and run-demo.sh run it (common.sh first, under
# set -uo pipefail, in the flow's own shell), then the two variables it may set.
AUTOTUNE='set -uo pipefail; . "$GS_REPO/src/lib/common.sh"; . "$LIB_DIR/cs2-tune.sh"
cs2_autotune
printf "after: GS_GPU_SCALE=%s CS2_FPS_MAX=%s\n" "${GS_GPU_SCALE-unset}" "${CS2_FPS_MAX-unset}"'

# tune_case NAME [GPU]: a case with 8 cores (nproc stub). With GPU, an nvidia-smi stub
# answers for that product name with a 2100 MHz max clock, and -pm and -lgc succeed;
# without it, the pod has no nvidia-smi.
tune_case() {
  t_case "$1"
  t_stub nproc 'echo 8'
  if [ -n "${2:-}" ]; then
    t_stub nvidia-smi "
case \"\$*\" in
  *--query-gpu=name*) echo '$2' ;;
  *clocks.max.gr*) echo 2100 ;;
esac"
  fi
}

# tune_text: stdout, stderr and the nvidia-smi calls of the last run, with U+2014 written
# as @EMDASH@.
tune_text() {
  local text
  text="$(printf 'stdout:\n%s\nstderr:\n%s\nnvidia-smi:\n%s\n' \
    "$T_STDOUT" "$T_STDERR" "$(t_calls nvidia-smi)")"
  printf '%s' "${text//"$DASH"/@EMDASH@}"
}

golden_autotune() {
  tune_case "unset vendor: RTX 3060" 'NVIDIA GeForce RTX 3060'
  t_run CS2_FPS_MAX=120 -- "$AUTOTUNE"
  t_golden autotune-unset-rtx3060 "$(tune_text)"

  tune_case "nvidia: GTX 980, the low tier" 'NVIDIA GeForce GTX 980'
  t_run GS_GPU_VENDOR=nvidia CS2_FPS_MAX=120 -- "$AUTOTUNE"
  t_golden autotune-nvidia-gtx980 "$(tune_text)"

  tune_case "nvidia: the clock lock refused" 'NVIDIA GeForce RTX 4070'
  t_stub nvidia-smi '
case "$*" in
  *--query-gpu=name*) echo "NVIDIA GeForce RTX 4070" ;;
  *clocks.max.gr*) echo 2100 ;;
  -lgc*) exit 6 ;;
esac'
  t_run GS_GPU_VENDOR=nvidia CS2_FPS_MAX=120 -- "$AUTOTUNE"
  t_golden autotune-nvidia-lgc-refused "$(tune_text)"

  tune_case "unset vendor: no nvidia-smi"
  t_run CS2_FPS_MAX=120 -- "$AUTOTUNE"
  t_golden autotune-unset-no-smi "$(tune_text)"

  tune_case "nvidia: a stray wsi_mode sw leaves the frame cap alone" 'NVIDIA GeForce RTX 3060'
  printf 'sw\n' > "$LOG_DIR/wsi_mode"
  t_run GS_GPU_VENDOR=nvidia CS2_FPS_MAX=300 GS_SW_WSI_FPS_MAX=60 -- "$AUTOTUNE"
  t_golden autotune-nvidia-stray-sw "$(tune_text)"
}

golden_autotune
if t_capture_mode; then t_done; fi

# AMD (S3-D14): the name from gpu_identity, the mid tier without classify_gpu_tier, no
# clock lock, and CS2_FPS_MAX through gs_sw_fps_clamp unless a clip batch has a cap above
# 0. Every case keeps an nvidia-smi stub on PATH to show that the AMD branch never calls it.
AMD_ADDR=0000:c6:00.0
AMD_NAME='AMD Radeon 8060S Graphics (RADV GFX1151)'
AMD_LINE="autotune: gpu='$AMD_NAME' tier=mid cores=8 GS_GPU_SCALE=auto (threads=engine auto-detect)"
SKIP_LINE='autotune: AMD GPU, clock lock skipped (pods write no DPM or clock files)'

# amd_tune_case NAME WSI [IDENTITY]: tune_case with the nvidia-smi stub, the f155ad35 GPU
# in sysfs, WSI (sw on tier A, hw on tier C) in $LOG_DIR/wsi_mode, and a gpu_identity file
# whose name line sits among the other keys (S3 interface [9]). IDENTITY no leaves it out
# (GS_SKIP_GPU_PREFLIGHT=1 may do that); noname writes it without the name line.
amd_tune_case() {
  local tier=A
  if [ "$2" = hw ]; then tier=C; fi
  tune_case "$1" 'NVIDIA GeForce RTX 3060'
  t_fake_gpu "$AMD_ADDR" 0x1002 0x1586 0x038000 renderD128
  printf '%s\n' "$2" > "$LOG_DIR/wsi_mode"
  case "${3:-yes}" in
    yes) printf '%s\n' "name=$AMD_NAME" > "$LOG_DIR/gpu_identity" ;;
    noname) : > "$LOG_DIR/gpu_identity" ;;
  esac
  if [ "${3:-yes}" != no ]; then
    printf '%s\n' vendor_id=0x1002 device_id=0x1586 "pci_address=$AMD_ADDR" \
      render_node=/dev/dri/renderD128 source=env "wsi=$2" "display_tier=$tier" \
      >> "$LOG_DIR/gpu_identity"
  fi
}

amd_tune() {
  t_run GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS="$AMD_ADDR" "$@" -- "$AUTOTUNE"
}

# amd_tune_ok: what every AMD run shows: rc 0, the skip line, no clock lock, nothing on
# stderr and no nvidia-smi call.
amd_tune_ok() {
  assert_rc 0 "rc 0"
  assert_contains "$T_STDOUT" "$SKIP_LINE" "one log line for the skipped clock lock"
  assert_not_contains "$T_STDOUT" "gpu clock lock" "no clock lock"
  assert_empty "$T_STDERR" "nothing on stderr"
  assert_empty "$(t_calls nvidia-smi)" "no nvidia-smi call"
}

amd_tune_case "amd: tier A sw clamps the live cap" sw
amd_tune GS_SW_WSI_FPS_MAX=60 CS2_FPS_MAX=120
amd_tune_ok
assert_contains "$T_STDOUT" "$AMD_LINE" "the gpu_identity name, mid tier, GS_GPU_SCALE auto"
assert_contains "$T_STDOUT" "autotune: sw WSI frame cap: fps_max 120 -> 60 (GS_SW_WSI_FPS_MAX)" \
  "the clamp is logged"
assert_contains "$T_STDOUT" "after: GS_GPU_SCALE=auto CS2_FPS_MAX=60" "120 clamped to 60"

amd_tune_case "amd: a clip batch keeps its launch cap" sw
amd_tune GS_SW_WSI_FPS_MAX=60 CS2_FPS_MAX=120 CLIP_BATCH_MODE=1
amd_tune_ok
assert_not_contains "$T_STDOUT" "frame cap" "no clamp"
assert_contains "$T_STDOUT" "after: GS_GPU_SCALE=auto CS2_FPS_MAX=120" "120 kept"

amd_tune_case "amd: a clip batch with cap 0 is still clamped" sw
amd_tune GS_SW_WSI_FPS_MAX=60 CS2_FPS_MAX=0 CLIP_BATCH_MODE=1
amd_tune_ok
assert_contains "$T_STDOUT" "autotune: sw WSI frame cap: fps_max 0 -> 60 (GS_SW_WSI_FPS_MAX)" \
  "the clamp is logged"
assert_contains "$T_STDOUT" "after: GS_GPU_SCALE=auto CS2_FPS_MAX=60" "0 clamped to 60"

amd_tune_case "amd: sw with the default GS_SW_WSI_FPS_MAX" sw
amd_tune CS2_FPS_MAX=300
amd_tune_ok
assert_contains "$T_STDOUT" "autotune: sw WSI frame cap: fps_max 300 -> 120 (GS_SW_WSI_FPS_MAX)" \
  "the clamp is logged"
assert_contains "$T_STDOUT" "after: GS_GPU_SCALE=auto CS2_FPS_MAX=120" "300 clamped to 120"

amd_tune_case "amd: tier C hw leaves the cap alone" hw
amd_tune GS_SW_WSI_FPS_MAX=60 CS2_FPS_MAX=0
amd_tune_ok
assert_not_contains "$T_STDOUT" "frame cap" "no clamp"
assert_contains "$T_STDOUT" "after: GS_GPU_SCALE=auto CS2_FPS_MAX=0" "0 kept"

amd_tune_case "amd: no gpu_identity assumes the mid tier (S3-E10)" hw no
amd_tune CS2_FPS_MAX=120
amd_tune_ok
assert_contains "$T_STDOUT" "autotune: $LOG_DIR/gpu_identity has no GPU name; assuming 'mid' tier" \
  "the missing name is logged"
assert_contains "$T_STDOUT" "autotune: gpu='unknown' tier=mid cores=8 GS_GPU_SCALE=auto" \
  "gpu unknown, mid tier"
assert_not_contains "$T_STDOUT$T_STDERR" "nvidia-smi unavailable" "no L80 WARN"

amd_tune_case "amd: gpu_identity without a name line (S3-E10)" sw noname
amd_tune CS2_FPS_MAX=120
amd_tune_ok
assert_contains "$T_STDOUT" "autotune: $LOG_DIR/gpu_identity has no GPU name; assuming 'mid' tier" \
  "the missing name is logged"
assert_contains "$T_STDOUT" "autotune: gpu='unknown' tier=mid cores=8 GS_GPU_SCALE=auto" \
  "gpu unknown, mid tier"

amd_tune_case "amd: an explicit GS_GPU_SCALE is kept" hw
amd_tune GS_GPU_SCALE=0 CS2_FPS_MAX=120
amd_tune_ok
assert_contains "$T_STDOUT" "tier=mid cores=8 GS_GPU_SCALE=0 (threads=engine auto-detect)" \
  "GS_GPU_SCALE=0 in the log line"
assert_contains "$T_STDOUT" "after: GS_GPU_SCALE=0 CS2_FPS_MAX=120" "GS_GPU_SCALE=0 kept"

amd_tune_case "amd: a nade batch keeps its launch cap" sw
amd_tune GS_SW_WSI_FPS_MAX=60 CS2_FPS_MAX=120 NADE_BATCH_MODE=1
amd_tune_ok
assert_not_contains "$T_STDOUT" "frame cap" "nade pacing headroom kept"
assert_contains "$T_STDOUT" "after: GS_GPU_SCALE=auto CS2_FPS_MAX=120" "120 kept"

amd_tune_case "amd: a nade batch with cap 0 is still clamped" sw
amd_tune GS_SW_WSI_FPS_MAX=60 CS2_FPS_MAX=0 NADE_BATCH_MODE=1
amd_tune_ok
assert_contains "$T_STDOUT" "fps_max 0 -> 60" "zero nade cap clamped"
assert_contains "$T_STDOUT" "after: GS_GPU_SCALE=auto CS2_FPS_MAX=60" "60 selected"
t_done
