# S5-U1: gs_gpu_sample (S3-D18, S5-D2) on a fake amdgpu sysfs tree. Each case sources
# src/lib/common.sh in a clean bash under set -uo pipefail, as the flows do, calls
# gs_gpu_sample once and checks the line, the exit code, that nothing went to stderr and
# that nothing outside LOG_DIR was written.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # the t_run scripts expand in the child shell
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

ADDR=0000:c6:00.0
ALL_UNKNOWN='util=? vramMiB=? clkMHz=? tempC=? vcn=?'

# gpu: the Radeon 8060S of f155ad35 with every file the sampler reads: 37 % busy,
# 2317852960 bytes of VRAM in use (2210.47 MiB), 2900123456 Hz (2900.12 MHz) and 58500
# millidegrees (58.5 C) in hwmon2, and 12 % VCN busy. Sets DEV to its sysfs directory.
gpu() {
  t_fake_gpu "$ADDR" 0x1002 0x1586 0x038000 renderD128
  DEV="$GS_SYSFS_ROOT/bus/pci/devices/$ADDR"
  mkdir -p "$DEV/hwmon/hwmon2"
  echo 37 > "$DEV/gpu_busy_percent"
  echo 2317852960 > "$DEV/mem_info_vram_used"
  echo 2900123456 > "$DEV/hwmon/hwmon2/freq1_input"
  echo 58500 > "$DEV/hwmon/hwmon2/temp1_input"
  echo 12 > "$DEV/vcn_busy_percent"
}

# sample [VAR=VALUE ...]: an AMD pod (vendor amd, address ADDR; later pairs win) that
# calls gs_gpu_sample once. A listing of everything under T_TMP except LOG_DIR and the
# run's own stdout and stderr files (path, size and mtime) is taken before and after the
# call; any difference is reported on stderr.
sample() {
  t_run GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS="$ADDR" "$@" -- 'set -uo pipefail
. "$GS_REPO/src/lib/common.sh"
snap() {
  find "$T_TMP" \( -path "$LOG_DIR" -o -path "$T_TMP/stdout" -o -path "$T_TMP/stderr" \) \
    -prune -o -printf "%p %s %T@\n" | LC_ALL=C sort
}
before="$(snap)"
gs_gpu_sample
rc=$?
if [ "$before" != "$(snap)" ]; then echo "gs_gpu_sample wrote outside LOG_DIR" >&2; fi
exit "$rc"'
}

# sample_is LABEL EXPECTED: the last run printed EXPECTED, exited 0 and was silent on stderr.
sample_is() {
  assert_rc 0 "$1: exit code"
  assert_eq "$2" "$T_STDOUT" "$1: line"
  assert_empty "$T_STDERR" "$1: stderr"
}

t_case "all files present: the format and the conversions"
gpu
sample
sample_is "all files" 'util=37 vramMiB=2210 clkMHz=2900 tempC=58 vcn=12'

# Each file missing in turn; the last one is the vcn-absent case of a kernel or GPU
# without the VCN file.
for f in gpu_busy_percent mem_info_vram_used hwmon/hwmon2/freq1_input \
  hwmon/hwmon2/temp1_input vcn_busy_percent; do
  t_case "missing $f"
  gpu
  rm "$DEV/$f"
  sample
  case "$f" in
    gpu_busy_percent) want='util=? vramMiB=2210 clkMHz=2900 tempC=58 vcn=12' ;;
    mem_info_vram_used) want='util=37 vramMiB=? clkMHz=2900 tempC=58 vcn=12' ;;
    */freq1_input) want='util=37 vramMiB=2210 clkMHz=? tempC=58 vcn=12' ;;
    */temp1_input) want='util=37 vramMiB=2210 clkMHz=2900 tempC=? vcn=12' ;;
    vcn_busy_percent) want='util=37 vramMiB=2210 clkMHz=2900 tempC=58 vcn=?' ;;
  esac
  sample_is "missing $f" "$want"
done

t_case "no hwmon directory"
gpu
rm -r "$DEV/hwmon"
sample
sample_is "no hwmon" 'util=37 vramMiB=2210 clkMHz=? tempC=? vcn=12'

t_case "hwmon0 empty and hwmon3 with the files"
gpu
rm -r "$DEV/hwmon/hwmon2"
mkdir -p "$DEV/hwmon/hwmon0" "$DEV/hwmon/hwmon3"
echo 1800000000 > "$DEV/hwmon/hwmon3/freq1_input"
echo 61000 > "$DEV/hwmon/hwmon3/temp1_input"
sample
sample_is "hwmon3" 'util=37 vramMiB=2210 clkMHz=1800 tempC=61 vcn=12'

t_case "each file comes from the lowest-numbered hwmon that has it, hwmon2 before hwmon10"
gpu
mkdir -p "$DEV/hwmon/hwmon1" "$DEV/hwmon/hwmon10"
rm "$DEV/hwmon/hwmon2/temp1_input"
echo 40000 > "$DEV/hwmon/hwmon1/temp1_input"
echo 1000000000 > "$DEV/hwmon/hwmon10/freq1_input"
echo 99000 > "$DEV/hwmon/hwmon10/temp1_input"
sample
sample_is "lowest hwmon" 'util=37 vramMiB=2210 clkMHz=2900 tempC=40 vcn=12'

# An empty or invalid address: empty, uppercase, no domain, no sysfs entry. The uppercase
# name exists in this sysfs with every file, so only the format check refuses it.
for addr in '' 0000:C6:00.0 c6:00.0 0000:c7:00.0; do
  t_case "address [$addr]"
  gpu
  cp -R "$DEV" "$GS_SYSFS_ROOT/bus/pci/devices/0000:C6:00.0"
  sample GS_GPU_PCI_ADDRESS="$addr"
  sample_is "address [$addr]" "$ALL_UNKNOWN"
done

t_case "non-numeric content"
gpu
echo N/A > "$DEV/gpu_busy_percent"
: > "$DEV/mem_info_vram_used"
echo 2.9e9 > "$DEV/hwmon/hwmon2/freq1_input"
echo 58.5 > "$DEV/hwmon/hwmon2/temp1_input"
echo 12% > "$DEV/vcn_busy_percent"
sample
sample_is "non-numeric" "$ALL_UNKNOWN"

t_done
