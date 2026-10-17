# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # child scripts and stubs expand at runtime
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

cpu_case() {
  t_case "$1"
  t_stub nproc 'echo "${CPU_NPROC:-16}"'
  t_stub taskset 'exit 0'
  t_stub pgrep 'case "$*" in
  *linuxsteamrt64/cs2*) echo 4242 ;;
  *hud-manager*) echo 4343 ;;
  *picom*) echo 4444 ;;
  *) exit 1 ;;
esac'
}
cpu_run() {
  t_run GS_CAPTURE_CORES_AUTO=2 CPU_ENC=x264enc "$@" -- 'set -uo pipefail
. "$GS_REPO/src/lib/common.sh"
compute_cpu_split
printf "before=%s|%s|%s\n" "$GS_CAPTURE_CPUS" "$GS_CS2_CPUS" "$GS_AUX_CPUS"
if [ "${CPU_SKIP_PARENT:-0}" != 1 ]; then gs_cpu_split_for_encoder "$CPU_ENC"; fi
if [ "${CPU_TWICE:-0}" = 1 ]; then gs_cpu_split_for_encoder "$CPU_ENC"; fi
printf "after=%s|%s|%s\npreset=%s\nauto=%s\n" "$GS_CAPTURE_CPUS" "$GS_CS2_CPUS" "$GS_AUX_CPUS" "${GS_CPU_SPLIT_PRESET-MISSING}" "$GS_CAPTURE_CORES_AUTO"
if [ -n "${CPU_PRESET_VAR:-}" ]; then printf "caller=%s\n" "${!CPU_PRESET_VAR}"; fi
if [ "${CPU_CHILD:-0}" = 1 ]; then
  bash -c '\''set -uo pipefail
. "$GS_REPO/src/lib/common.sh"
gs_cpu_split_for_encoder x264enc
printf "child=%s|%s|%s\npreset-child=%s\n" "$GS_CAPTURE_CPUS" "$GS_CS2_CPUS" "$GS_AUX_CPUS" "${GS_CPU_SPLIT_PRESET-MISSING}"'\''
fi'
}

for ncpu in 6 8 16; do
  for enc in nvcudah264enc x264enc; do
    cpu_case "$ncpu CPUs: $enc after a self-filled launch split"
    cpu_run CPU_NPROC="$ncpu" CPU_ENC="$enc"
    case "$ncpu:$enc" in
      6:*) before='4-5|0-3|'; expected="$before"; auto=2 ;;
      8:x264enc) before='6-7|0-5|'; expected='4-7|0-3|'; auto=4 ;;
      16:x264enc) before='14-15|0-12|13-13'; expected='12-15|0-10|11-11'; auto=4 ;;
      8:*) before='6-7|0-5|'; expected="$before"; auto=2 ;;
      16:*) before='14-15|0-12|13-13'; expected="$before"; auto=2 ;;
    esac
    assert_eq 0 "$T_RC" 'split completes'
    assert_contains "$T_STDOUT" "before=$before" 'original launch allocation'
    assert_contains "$T_STDOUT" "after=$expected" 'resolved encoder allocation'
    assert_contains "$T_STDOUT" $'preset=\n' 'filled lists remain distinguishable from caller presets'
    assert_contains "$T_STDOUT" "auto=$auto" 'automatic count changes only for eligible CPU capture'
    if [ "$auto" = 4 ]; then
      cpus='0-3'; [ "$ncpu" != 16 ] || cpus='0-10'
      assert_contains "$(t_calls taskset)" "-a -p -c $cpus 4242" 'CS2 is pinned again'
      if [ "$ncpu" = 16 ]; then
        assert_contains "$(t_calls taskset)" '-a -p -c 11-11 4343' 'HUD follows the new auxiliary core'
        assert_contains "$(t_calls taskset)" '-a -p -c 11-11 4444' 'picom follows the new auxiliary core'
      fi
    else
      assert_empty "$(t_calls taskset)" 'GPU and small-node affinity stays unchanged'
    fi
  done
done

for cap in 1 2 3 ''; do
  cpu_case "explicit CAPTURE_CORES=$cap wins"
  cpu_run CPU_NPROC=8 CAPTURE_CORES="$cap"
  expected='6-7|0-5|'
  [ "$cap" != 1 ] || expected='7-7|0-6|'
  [ "$cap" != 3 ] || expected='5-7|0-4|'
  assert_eq 0 "$T_RC" 'explicit count completes'
  assert_contains "$T_STDOUT" "before=$expected" 'explicit launch count'
  assert_contains "$T_STDOUT" "after=$expected" 'explicit count retained, including empty-as-default'
  assert_contains "$T_STDOUT" 'auto=2' 'CPU helper keeps the explicit choice'
  assert_empty "$(t_calls taskset)" 'explicit allocation is not replaced'
done

for preset in CAPTURE_CPUS CS2_CPUS AUX_CPUS; do
  for value in 1-2 ''; do
    cpu_case "caller preset $preset=$value"
    cpu_run CPU_NPROC=16 CPU_PRESET_VAR="$preset" "$preset=$value"
    before=$(grep '^before=' <<< "$T_STDOUT"); after=$(grep '^after=' <<< "$T_STDOUT")
    assert_eq 0 "$T_RC" 'preset completes'
    assert_eq "${before#before=}" "${after#after=}" 'all launch lists stay when any caller list was preset'
    assert_eq "caller=$value" "$(grep '^caller=' <<< "$T_STDOUT")" 'original value survives, including empty'
    assert_contains "$T_STDOUT" "preset=$preset" 'original preset identity is recorded'
    assert_contains "$T_STDOUT" 'auto=2' 'no CPU automatic override behind a caller list'
    assert_empty "$(t_calls taskset)" 'preset affinity is not replaced'
  done
done

cpu_case 'measured AMD automatic three-core input loses to CPU encoding'
cpu_run CPU_NPROC=16 GS_CAPTURE_CORES_AUTO=3
assert_eq 0 "$T_RC" 'conditional input completes'
assert_contains "$T_STDOUT" 'before=13-15|0-11|12-12' 'measured starting split'
assert_contains "$T_STDOUT" 'after=12-15|0-10|11-11' 'CPU count wins over that default'
assert_contains "$T_STDOUT" 'auto=4' 'CPU automatic value survives'

cpu_case 'child sees which launch values were self-filled'
cpu_run CPU_NPROC=8 CPU_SKIP_PARENT=1 CPU_CHILD=1
assert_eq 0 "$T_RC" 'child completes'
assert_contains "$T_STDOUT" 'child=4-7|0-3|' 'child recalculates self-filled lists'
assert_eq 'preset-child=' "$(grep '^preset-child=' <<< "$T_STDOUT")" 'preset tracking was exported'

cpu_case 'CPU helper is idempotent after the re-pin'
cpu_run CPU_NPROC=8 CPU_TWICE=1
assert_eq 0 "$T_RC" 'repeated helper completes'
assert_contains "$T_STDOUT" 'after=4-7' 'four-core allocation survives'
assert_eq 1 "$(t_calls taskset | grep -c 4242 || true)" 'CS2 is pinned once for the transition'

t_done
