# S3-U17: real timeout calls, bounded hanging readers, no GPU or server packages.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=lib/tierc-test-fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/tierc-test-fixtures.sh"

for probe in query root randr; do
  selftest_case "hung self-test reader: $probe"
  t_stub xdpyinfo 'case "$*" in
  *-queryExtensions*)
    if [ "$HANG_PROBE" = query ]; then echo $$ > "$T_TMP/hung.pid"; exec sleep 600; fi
    echo "DRI3" ;;
  *)
    if [ "$HANG_PROBE" = root ]; then echo $$ > "$T_TMP/hung.pid"; exec sleep 600; fi
    echo "dimensions: 1920x1080 pixels" ;;
esac'
  t_stub xrandr 'if [ "$HANG_PROBE" = randr ]; then echo $$ > "$T_TMP/hung.pid"; exec sleep 600; fi
echo "1920x1080 60.0*"'
  selftest_run HANG_PROBE="$probe"
  assert_rc 0 'bounded wrapper completes'
  if [ "$probe" = query ]; then expected=no-dri3; else expected=root-size; fi
  assert_contains "$T_STDOUT" "rc=1 reason=$expected" 'timeout becomes its stage failure'
  assert_match 'probe-elapsed=[0-6]($|[^0-9])' "$T_STDOUT" 'the shipped self-test returns within six seconds'
  pid=$(cat "$T_TMP/hung.pid")
  state='gone'
  if [ -r "/proc/$pid/stat" ]; then
    state=$(<"/proc/$pid/stat"); state="${state##*) }"; state="${state%% *}"
  fi
  assert_match '^(gone|Z)$' "$state" 'no live hanging reader survives timeout'
done

for first_hang in 1 2; do
  walk_case "display walk hangs from probe $first_hang"
  t_stub xdpyinfo 'n=0
[ ! -f "$T_TMP/probe-count" ] || read -r n < "$T_TMP/probe-count"
n=$((n+1)); echo "$n" > "$T_TMP/probe-count"
if [ "$n" -lt "$FIRST_HANG" ]; then exit 1; fi
echo $$ > "$T_TMP/hung.pid"; exec sleep 600'
  started=$SECONDS
  walk_run WALK_MODE=good FIRST_HANG="$first_hang"
  assert_rc 0 'bounded walker returns'
  assert_contains "$T_STDOUT" 'rc=1 reason=xwayland-failed' 'readiness timeout classification'
  assert_contains "$T_STDOUT" 'timeout waiting 10s' 'timeout detail'
  assert_match '^([0-9]|1[0-9]|2[01])$' "$((SECONDS-started))" 'initial check plus readiness and cleanup bound'
  assert_contains "$(cat "$T_TMP/xw-argv.20")" ':20 -geometry' 'a hung probe does not skip :20'
  assert_no_file "$T_TMP/xw-argv.21" 'timeout aborts this attempt'
done

t_case 'recorded tier C liveness has a five-second X reply timeout'
t_stub xdpyinfo 'exec sleep 600'
t_run GS_PROC_ROOT=/proc GS_GPU_VENDOR=amd -- 'set -uo pipefail
. "$GS_REPO/src/lib/xorg.sh"
echo "C requested" > "$LOG_DIR/display_tier"
sleep 600 & a=$!; sleep 600 & b=$!
trap '\''kill -KILL "$a" "$b" 2>/dev/null || true; wait "$a" "$b" 2>/dev/null || true'\'' EXIT
sleep 0.1
_tier_c_record_pid "$a" "$LOG_DIR/xwayland.pid"
_tier_c_record_pid "$b" "$LOG_DIR/weston.pid"
started=$SECONDS; rc=0
_tier_c_running || rc=$?
printf "running=%s probe-elapsed=%s\n" "$rc" "$((SECONDS-started))"'
assert_rc 0 'fixture cleanup completes'
assert_contains "$T_STDOUT" running=1 'hung server is not running'
assert_match 'probe-elapsed=[0-6]($|[^0-9])' "$T_STDOUT" 'liveness call returns within six seconds'

for tier in A absent; do
  t_case "tier $tier WSI probes a hung X server and selects sw"
  t_stub xdpyinfo 'exec sleep 600'
  t_run GS_GPU_VENDOR=amd TIMING_TIER="$tier" -- 'set -uo pipefail
. "$GS_REPO/src/lib/xorg.sh"
if [ "$TIMING_TIER" = A ]; then echo "A requested" > "$LOG_DIR/display_tier"; fi
unset MESA_VK_WSI_DEBUG
started=$SECONDS
_xorg_wsi_probe
printf "wsi=%s debug=%s probe-elapsed=%s\n" "$(cat "$LOG_DIR/wsi_mode")" "${MESA_VK_WSI_DEBUG-}" "$((SECONDS-started))"'
  assert_rc 0 'bounded software WSI decision'
  assert_contains "$T_STDOUT" 'wsi=sw debug=sw' 'timeout selects software present'
  assert_match 'probe-elapsed=[0-6]($|[^0-9])' "$T_STDOUT" 'WSI call returns within six seconds'
done

t_case 'tier C WSI writes hw without calling even a hung xdpyinfo'
t_stub xdpyinfo 'exec sleep 600'
t_run GS_GPU_VENDOR=amd -- 'set -uo pipefail
. "$GS_REPO/src/lib/xorg.sh"
echo "C requested" > "$LOG_DIR/display_tier"
unset MESA_VK_WSI_DEBUG
_xorg_wsi_probe
printf "wsi=%s debug=<%s>\n" "$(cat "$LOG_DIR/wsi_mode")" "${MESA_VK_WSI_DEBUG-}"'
assert_rc 0 'no second tier C DRI3 probe'
assert_contains "$T_STDOUT" 'wsi=hw debug=<>' 'hardware WSI and no sw override'
assert_eq '' "$(t_calls xdpyinfo)" 'no hung probe is started'
t_done
