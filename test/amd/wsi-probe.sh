# S3 change C7: the AMD DRI3 probe that start_xorg runs once its X server answers (S3-D9,
# S3-D31), the $LOG_DIR/wsi_mode it writes (S3 interface [8]) and the MESA_VK_WSI_DEBUG it
# exports (interface [7]). A fresh bash sources src/lib/common.sh and src/lib/xorg.sh under
# set -uo pipefail, as src/flows/setup-steam.sh does, with timeout, xdpyinfo, pgrep, xhost,
# xprop, sleep and Xorg stubbed. xdpyinfo -queryExtensions prints the xdpy_dump fixture of
# lib/dumps.sh, with or without DRI3. The start_xorg runs cover the already-up path, the
# walk and the coexist fallback, GS_SKIP_GPU_PREFLIGHT (S3-E9), and NVIDIA and no vendor,
# which never probe. The direct runs of _xorg_wsi_probe cover a failed and a timed-out
# xdpyinfo (S3-E6), a preset MESA_VK_WSI_DEBUG (S3-E5) and tier C (S3-E27). The 50-run
# loops of S3-U16 are in pipefail-probes.sh.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # the t_run scripts and stub bodies expand in the child shell
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=lib/dumps.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/dumps.sh"

AMD_ADDR=0000:c6:00.0
AMD_ENV=(HOSTNAME=gs-wsi GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS="$AMD_ADDR")
# The probe's call as the timeout stub records it, on the AMD base display :20.
QUERY='5 xdpyinfo -display :20 -queryExtensions'
HW_LOG='[setup-steam] xorg: wsi_mode=hw on :20 (DRI3 listed)'
TIER_C_LOG='[setup-steam] xorg: wsi_mode=hw on :20 (tier C: its self-test found DRI3)'
SW_LOG='[setup-steam] xorg: wsi_mode=sw on :20 (no DRI3 listed, or xdpyinfo failed), MESA_VK_WSI_DEBUG='
WARN_LINEAR="[setup-steam] WARN: xorg: MESA_VK_WSI_DEBUG='linear' is preset without sw and is kept, but :20 lists no DRI3 (or xdpyinfo failed), so RADV can fail with 'No DRI3 support detected'"

# How setup-steam.sh loads xorg.sh. stdin is never a terminal, so nohup in spawn_logged
# prints nothing, and the EXIT trap waits for the background Xorg stub.
LIBS='exec </dev/null
set -uo pipefail
SCRIPT_TAG=setup-steam
. "$GS_REPO/src/lib/common.sh"
. "$LIB_DIR/xorg.sh"
trap wait EXIT'

# Printed right after the call under test: its exit code, MESA_VK_WSI_DEBUG in this shell
# and what a child process sees.
REPORT='echo "rc=$?"
echo "shell=${MESA_VK_WSI_DEBUG-unset}"
echo "child=$(printenv MESA_VK_WSI_DEBUG || echo unset)"'

# Shell functions for the coexist fallback: every Xorg exits at once (kill -0 fails), the
# Xorg logs report 'no screens found' while $T_TMP/no-screens exists, and the log cleanup
# before the dummy retry (src/lib/xorg.sh baseline L236) clears that flag.
FAKES='kill() { if [ "${1:-}" = -0 ]; then return 1; fi; return 0; }
grep() {
  if [ "$#" -eq 3 ] && [ "$1" = -qs ] && [ "$2" = "no screens found" ]; then
    case "$3" in
      /var/log/Xorg.*.log) [ -e "$T_TMP/no-screens" ]; return ;;
    esac
  fi
  command grep "$@"
}
rm() {
  if [ "$*" = "-f /var/log/Xorg.*.log" ]; then command rm -f "$T_TMP/no-screens"; return 0; fi
  command rm "$@"
}'

# wp_case NAME FAILS DUMP RC GPU
# Starts the case NAME with the X tool stubs. xdpyinfo fails its first FAILS display
# checks, then answers and marks X up (FAILS 0: X is up before start_xorg). xdpyinfo
# -queryExtensions prints DUMP (dri3: the xdpy_dump fixture; nodri3: the same without DRI3;
# none: nothing) and exits RC. timeout runs its command with no time limit, pgrep sees
# openbox always and Xorg once X is up, and Xorg writes its argv to $T_TMP/spawn.Xorg. GPU
# amd puts this pod's GPU, 0000:c6:00.0, in the fake sysfs; GPU nvidia makes the node an
# NVIDIA node (a GTX 980 and the NVIDIA driver loaded).
wp_case() {
  t_case "$1"
  printf '%s\n' "$2" > "$T_TMP/xdpy.fail"
  if [ "$2" = 0 ]; then : > "$T_TMP/x.up"; fi
  case "$3" in
    dri3) xdpy_dump > "$T_TMP/ext.out" ;;
    nodri3) xdpy_dump -x DRI3 > "$T_TMP/ext.out" ;;
    none) : > "$T_TMP/ext.out" ;;
  esac
  printf '%s\n' "$4" > "$T_TMP/ext.rc"
  t_stub timeout 'shift; exec "$@"'
  t_stub xdpyinfo 'if [ "${3:-}" = -queryExtensions ]; then
  cat "$T_TMP/ext.out"
  read -r rc < "$T_TMP/ext.rc"
  exit "$rc"
fi
n=0
if [ -r "$T_TMP/xdpy.count" ]; then read -r n < "$T_TMP/xdpy.count"; fi
n=$((n + 1))
echo "$n" > "$T_TMP/xdpy.count"
read -r k < "$T_TMP/xdpy.fail"
if [ "$n" -le "$k" ]; then exit 1; fi
: > "$T_TMP/x.up"'
  t_stub pgrep 'case "$*" in
  "-x Xorg") [ -e "$T_TMP/x.up" ] ;;
  "-x openbox") exit 0 ;;
  *) exit 1 ;;
esac'
  t_stub xhost
  t_stub xprop
  t_stub sleep
  cat > "$T_BIN/Xorg" <<'STUB'
#!/usr/bin/env bash
echo "Xorg $*" >> "$T_TMP/spawn.Xorg"
STUB
  chmod +x "$T_BIN/Xorg"
  if [ "$5" = amd ]; then
    t_fake_gpu "$AMD_ADDR" 0x1002 0x1586 0x038000 renderD128
  else
    t_fake_gpu 0000:01:00.0 0x10de 0x13c0
    mkdir -p "$GS_PROC_ROOT/driver/nvidia"
  fi
}

# wsi_file: the bytes of $LOG_DIR/wsi_mode with each newline written as \n, or 'missing'.
wsi_file() {
  local s
  if [ ! -e "$LOG_DIR/wsi_mode" ]; then printf missing; return; fi
  s="$(cat "$LOG_DIR/wsi_mode"; printf x)"
  s="${s%x}"
  printf '%s' "${s//$'\n'/\\n}"
}

# n_queries: how many times the probe ran xdpyinfo -queryExtensions through timeout.
n_queries() {
  local line n=0
  while IFS= read -r line; do
    if [ "$line" = "$QUERY" ]; then n=$((n + 1)); fi
  done < <(t_calls timeout)
  echo "$n"
}

# The probe through start_xorg. The calls end with the _GS_STREAMER xprop line and then
# the probe, so the probe runs once X answers, after the walk and the fallback.
wp_case "already up, no DRI3: wsi_mode sw and MESA_VK_WSI_DEBUG=sw" 0 nodri3 0 amd
t_run "${AMD_ENV[@]}" -- "$LIBS
start_xorg
$REPORT"
assert_rc 0 "already up: exits 0"
assert_eq 'sw\n' "$(wsi_file)" "already up: wsi_mode holds the line sw"
assert_contains "$T_STDOUT" "rc=0" "already up: start_xorg returns 0"
assert_contains "$T_STDOUT" "shell=sw" "already up: MESA_VK_WSI_DEBUG=sw in this shell"
assert_contains "$T_STDOUT" "child=sw" "already up: MESA_VK_WSI_DEBUG=sw is exported"
assert_contains "$T_STDOUT" "${SW_LOG}sw" "already up: the sw log line"
assert_empty "$T_STDERR" "already up: no WARN and no error"
assert_eq 1 "$(n_queries)" "already up: one xdpyinfo -queryExtensions through timeout 5"
assert_eq "xprop -root -f _GS_STREAMER 8s -set _GS_STREAMER gs-wsi
timeout $QUERY
xdpyinfo -display :20 -queryExtensions" "$(tail -n 3 "$T_CALLS")" \
  "already up: the probe is the last thing start_xorg does, after the _GS_STREAMER xprop"
t_run "${AMD_ENV[@]}" -- '. "$GS_REPO/src/lib/common.sh"
printenv MESA_VK_WSI_DEBUG || echo unset'
assert_eq sw "$T_STDOUT" "already up: a later shell gets MESA_VK_WSI_DEBUG=sw from wsi_mode"

wp_case "already up, DRI3 listed: wsi_mode hw and no MESA_VK_WSI_DEBUG" 0 dri3 0 amd
t_run "${AMD_ENV[@]}" -- "$LIBS
start_xorg
$REPORT"
assert_rc 0 "dri3: exits 0"
assert_eq 'hw\n' "$(wsi_file)" "dri3: wsi_mode holds the line hw"
assert_contains "$T_STDOUT" "rc=0" "dri3: start_xorg returns 0"
assert_contains "$T_STDOUT" "shell=unset" "dri3: MESA_VK_WSI_DEBUG stays unset in this shell"
assert_contains "$T_STDOUT" "child=unset" "dri3: and in a child"
assert_contains "$T_STDOUT" "$HW_LOG" "dri3: the hw log line"
assert_empty "$T_STDERR" "dri3: no WARN and no error"
assert_eq 1 "$(n_queries)" "dri3: one xdpyinfo -queryExtensions through timeout 5"
t_run "${AMD_ENV[@]}" -- '. "$GS_REPO/src/lib/common.sh"
printenv MESA_VK_WSI_DEBUG || echo unset'
assert_eq unset "$T_STDOUT" "dri3: a later shell exports no MESA_VK_WSI_DEBUG"

wp_case "fresh start on :20, no DRI3: the probe runs after the walk" 1 nodri3 0 amd
t_run "${AMD_ENV[@]}" -- "$LIBS
start_xorg
$REPORT"
assert_rc 0 "fresh: exits 0"
assert_contains "$(cat "$T_TMP/spawn.Xorg" 2>/dev/null)" "Xorg :20 " "fresh: Xorg was started on :20"
assert_eq 'sw\n' "$(wsi_file)" "fresh: wsi_mode sw"
assert_contains "$T_STDOUT" "child=sw" "fresh: MESA_VK_WSI_DEBUG=sw is exported"
assert_contains "$T_STDOUT" "${SW_LOG}sw" "fresh: the sw log line"
assert_eq 1 "$(n_queries)" "fresh: one xdpyinfo -queryExtensions"
assert_not_contains "$T_STDERR" "MESA_VK_WSI_DEBUG" "fresh: no WSI WARN"
assert_not_contains "$T_STDERR" "unbound variable" "fresh: no unbound variable"

wp_case "coexist fallback, no DRI3: the probe runs after the dummy retry" 21 nodri3 0 amd
: > "$T_TMP/no-screens"
t_run "${AMD_ENV[@]}" -- "$LIBS
$FAKES
start_xorg
$REPORT"
assert_rc 0 "coexist: exits 0"
assert_contains "$T_STDOUT" "retrying with offscreen dummy X" "coexist: the dummy retry ran"
assert_eq 'sw\n' "$(wsi_file)" "coexist: wsi_mode sw"
assert_contains "$T_STDOUT" "child=sw" "coexist: MESA_VK_WSI_DEBUG=sw is exported"
assert_eq 1 "$(n_queries)" "coexist: one xdpyinfo -queryExtensions, after the retry"
assert_not_contains "$T_STDERR" "MESA_VK_WSI_DEBUG" "coexist: no WSI WARN"
assert_not_contains "$T_STDERR" "unbound variable" "coexist: no unbound variable"

wp_case "GS_SKIP_GPU_PREFLIGHT=1 does not skip the probe (S3-E9)" 0 nodri3 0 amd
t_run "${AMD_ENV[@]}" GS_SKIP_GPU_PREFLIGHT=1 -- "$LIBS
start_xorg
$REPORT"
assert_rc 0 "skip: exits 0"
assert_eq 'sw\n' "$(wsi_file)" "skip: wsi_mode sw"
assert_contains "$T_STDOUT" "child=sw" "skip: MESA_VK_WSI_DEBUG=sw is exported"
assert_eq 1 "$(n_queries)" "skip: one xdpyinfo -queryExtensions"

for v in nvidia unset; do
  wp_case "$v: start_xorg never probes and writes no wsi_mode" 0 nodri3 0 nvidia
  run_env=(HOSTNAME=gs-wsi)
  if [ "$v" = nvidia ]; then run_env+=(GS_GPU_VENDOR=nvidia); fi
  t_run "${run_env[@]}" -- "$LIBS
start_xorg
$REPORT"
  assert_rc 0 "$v: exits 0"
  assert_contains "$T_STDOUT" "rc=0" "$v: start_xorg returns 0"
  assert_not_contains "$(cat "$T_CALLS")" "-queryExtensions" "$v: no xdpyinfo -queryExtensions"
  assert_no_file "$LOG_DIR/wsi_mode" "$v: no wsi_mode file"
  assert_contains "$T_STDOUT" "shell=unset" "$v: no MESA_VK_WSI_DEBUG"
  assert_contains "$T_STDOUT" "child=unset" "$v: no MESA_VK_WSI_DEBUG in a child"
  assert_not_contains "$T_STDOUT" "wsi_mode" "$v: no wsi_mode log line"
  assert_empty "$T_STDERR" "$v: nothing on stderr"
done

# The probe alone, in the shell where start_xorg would call it.
PROBE="$LIBS
_xorg_wsi_probe
$REPORT"

wp_case "xdpyinfo fails after printing DRI3: sw (S3-E6)" 0 dri3 1 amd
t_run "${AMD_ENV[@]}" -- "$PROBE"
assert_contains "$T_STDOUT" "rc=0" "xdpyinfo exit 1: the probe returns 0"
assert_eq 'sw\n' "$(wsi_file)" "xdpyinfo exit 1: wsi_mode sw, the output is not trusted"
assert_contains "$T_STDOUT" "child=sw" "xdpyinfo exit 1: MESA_VK_WSI_DEBUG=sw is exported"
assert_contains "$T_STDOUT" "${SW_LOG}sw" "xdpyinfo exit 1: the sw log line"
assert_empty "$T_STDERR" "xdpyinfo exit 1: no WARN"

wp_case "xdpyinfo times out: sw (S3-E6)" 0 none 124 amd
t_run "${AMD_ENV[@]}" -- "$PROBE"
assert_contains "$T_STDOUT" "rc=0" "timeout: the probe returns 0"
assert_eq 'sw\n' "$(wsi_file)" "timeout: wsi_mode sw"
assert_contains "$T_STDOUT" "child=sw" "timeout: MESA_VK_WSI_DEBUG=sw is exported"
assert_eq 1 "$(n_queries)" "timeout: the call has the 5 s limit"

wp_case "tier A, preset linear, no DRI3: kept, with the WARN (S3-E5)" 0 nodri3 0 amd
t_run "${AMD_ENV[@]}" MESA_VK_WSI_DEBUG=linear -- "$PROBE"
assert_contains "$T_STDOUT" "rc=0" "preset linear: the probe returns 0"
assert_eq 'sw\n' "$(wsi_file)" "preset linear: wsi_mode sw"
assert_contains "$T_STDOUT" "shell=linear" "preset linear: the preset is kept"
assert_contains "$T_STDOUT" "child=linear" "preset linear: and exported unchanged"
assert_eq "$WARN_LINEAR" "$T_STDERR" "preset linear: the WARN"
assert_contains "$T_STDOUT" "${SW_LOG}linear" "preset linear: the sw log line names the kept value"

wp_case "tier A, preset linear, DRI3 listed: kept, no WARN" 0 dri3 0 amd
t_run "${AMD_ENV[@]}" MESA_VK_WSI_DEBUG=linear -- "$PROBE"
assert_eq 'hw\n' "$(wsi_file)" "preset linear, dri3: wsi_mode hw"
assert_contains "$T_STDOUT" "child=linear" "preset linear, dri3: the preset is kept"
assert_empty "$T_STDERR" "preset linear, dri3: no WARN"

wp_case "tier A, preset sw,linear, no DRI3: kept, no WARN" 0 nodri3 0 amd
t_run "${AMD_ENV[@]}" MESA_VK_WSI_DEBUG=sw,linear -- "$PROBE"
assert_eq 'sw\n' "$(wsi_file)" "preset sw,linear: wsi_mode sw"
assert_contains "$T_STDOUT" "child=sw,linear" "preset sw,linear: the preset is kept"
assert_contains "$T_STDOUT" "${SW_LOG}sw,linear" "preset sw,linear: the sw log line"
assert_empty "$T_STDERR" "preset sw,linear: no WARN"

# Tier C: part 08 writes $LOG_DIR/display_tier in start_xorg before this point; the cases
# write it themselves (S3 interface [30]).
wp_case "tier C requested: hw without a probe, even on a dump without DRI3 (S3-E27)" 0 nodri3 0 amd
printf '%s\n' 'C requested' > "$LOG_DIR/display_tier"
t_run "${AMD_ENV[@]}" -- "$PROBE"
assert_contains "$T_STDOUT" "rc=0" "tier C: the probe returns 0"
assert_eq 'hw\n' "$(wsi_file)" "tier C: wsi_mode hw"
assert_contains "$T_STDOUT" "$TIER_C_LOG" "tier C: the tier C log line"
assert_empty "$(t_calls timeout)" "tier C: no timeout call"
assert_empty "$(t_calls xdpyinfo)" "tier C: no xdpyinfo call"
assert_contains "$T_STDOUT" "shell=unset" "tier C: MESA_VK_WSI_DEBUG stays unset"
assert_contains "$T_STDOUT" "child=unset" "tier C: and in a child"
assert_empty "$T_STDERR" "tier C: no WARN"

wp_case "tier C default, preset linear: kept silently" 0 nodri3 0 amd
printf '%s\n' 'C default' > "$LOG_DIR/display_tier"
t_run "${AMD_ENV[@]}" MESA_VK_WSI_DEBUG=linear -- "$PROBE"
assert_eq 'hw\n' "$(wsi_file)" "tier C, preset linear: wsi_mode hw"
assert_contains "$T_STDOUT" "child=linear" "tier C, preset linear: the preset is kept"
assert_empty "$T_STDERR" "tier C, preset linear: no WARN"
assert_empty "$(t_calls xdpyinfo)" "tier C, preset linear: no xdpyinfo call"

wp_case "tier A after a tier C fallback: the probe runs" 0 nodri3 0 amd
printf '%s\n' 'A fallback:no-dri3' > "$LOG_DIR/display_tier"
t_run "${AMD_ENV[@]}" -- "$PROBE"
assert_eq 'sw\n' "$(wsi_file)" "A fallback: wsi_mode sw"
assert_eq 1 "$(n_queries)" "A fallback: one xdpyinfo -queryExtensions"
assert_contains "$T_STDOUT" "child=sw" "A fallback: MESA_VK_WSI_DEBUG=sw is exported"

t_done
