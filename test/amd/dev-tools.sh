# Unit tests for the dev tools src/dev/capture-info.sh (S4 C25) and
# src/dev/profile-capture.sh (S3 C20 and S4 C26). The spec lists no unit tests for these
# items; these cases are the plan's own.
#
# The NVIDIA output of both tools stays byte-identical to the upstream commit: the golden_*
# functions run each tool with stubbed nvidia-smi, gst-inspect-1.0, gst-launch-1.0, pgrep,
# ps, nproc, getconf, sleep and join (GS_GPU_VENDOR unset) and compare the exit status,
# stdout, stderr and the nvidia-smi calls with the goldens captured there. Upstream's
# U+2014 is written as @EMDASH@ in the goldens. The AMD cases run after the golden
# functions and never in capture mode.
#
# profile-capture.sh reads /proc/<pid>/cmdline and /proc/<pid>/stat. The pgrep stub answers
# with the pid self/root<case temp dir>/proc-<name>, so those paths resolve to the files
# fake_proc writes under $T_TMP.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # t_run scripts and stub bodies expand in the child shell
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=lib/golden.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/golden.sh"

DASH="$(printf '\342\200\224')"

# tool_text: the exit status, stdout and stderr of the last t_run and the recorded
# nvidia-smi calls, with U+2014 written as @EMDASH@.
tool_text() {
  local text
  text="$(printf 'rc=%s\n== stdout\n%s\n== stderr\n%s\n== nvidia-smi calls\n%s' \
    "$T_RC" "$T_STDOUT" "$T_STDERR" "$(t_calls nvidia-smi)")"
  printf '%s' "${text//"$DASH"/@EMDASH@}"
}

# nvidia_smi_stub: an RTX 3060 that answers every query the two tools make.
nvidia_smi_stub() {
  t_stub nvidia-smi 'case "$*" in
  *--query-gpu=name*) echo "NVIDIA GeForce RTX 3060" ;;
  *--query-gpu=clocks.max.gr*) echo 2100 ;;
  *--query-gpu=utilization.gpu,utilization.memory*) echo "37, 12" ;;
  dmon*) printf "# gpu    sm   mem   enc   dec\n# Idx     %%     %%     %%     %%\n    0    37    12    20     0\n" ;;
esac'
}

# gst_stubs [missing-element]: every element exists and has the AQ properties, except the
# one named, and every gst-launch-1.0 probe passes.
gst_stubs() {
  t_stub gst-inspect-1.0 "case \"\${1:-}\" in
  ${1:-no-such-element}) exit 1 ;;
esac
printf '  spatial-aq          : Spatial AQ\n  temporal-aq         : Temporal AQ\n'"
  t_stub gst-launch-1.0
}

# fake_proc NAME WORD...: a process for the pgrep stub: its cmdline (NUL-separated words)
# and a stat line with utime 250 and stime 50 jiffies.
fake_proc() {
  local name="$1" dir="$T_TMP/proc-$1"
  shift
  mkdir -p "$dir"
  printf '%s\0' "$@" > "$dir/cmdline"
  printf '4242 (%s) S 1 4242 4242 0 -1 4194560 100 0 0 0 250 50 0 0 20 0 8 0 100 0 0\n' \
    "$name" > "$dir/stat"
}

# profile_stubs: pgrep finds the fake processes that PG_GST_PATTERN (the pattern that
# finds the capture process) and PG_CS2=1 name; ps, sleep, getconf, nproc and join answer
# without the host, so a run takes no time and finds no hot cores.
profile_stubs() {
  t_stub pgrep 'case "${2:-}" in
  "${PG_GST_PATTERN:-}") [ -n "${PG_GST_PATTERN:-}" ] && echo "self/root$T_TMP/proc-gst" ;;
  /linuxsteamrt64/cs2) [ "${PG_CS2:-0}" = 1 ] && echo "self/root$T_TMP/proc-cs2" ;;
esac
exit 0'
  t_stub ps 'printf "    TID %%CPU COMMAND\n   4242 55.0 gst-launch-1.0\n   4243 12.5 videoconvert0:sr\n"'
  t_stub sleep
  t_stub getconf 'echo 100'
  t_stub nproc 'echo 8'
  t_stub join
}

golden_capture_info() {
  t_case "nvidia: capture-info h264 with nvcudah264enc and cudaconvertscale"
  nvidia_smi_stub
  gst_stubs
  t_stub nproc 'echo 8'
  t_run GS_PROBE_CACHE="$T_TMP/gst-probes.env" -- 'bash "$GS_REPO/src/dev/capture-info.sh" h264'
  t_golden capture-info-h264 "$(tool_text)"

  t_case "nvidia: capture-info h264 with nvcudah264enc and no cudaconvertscale"
  nvidia_smi_stub
  gst_stubs cudaconvertscale
  t_stub nproc 'echo 8'
  t_run GS_PROBE_CACHE="$T_TMP/gst-probes.env" -- 'bash "$GS_REPO/src/dev/capture-info.sh" h264'
  t_golden capture-info-cudaupload "$(tool_text)"

  t_case "nvidia: capture-info h265 without NVENC and without nvidia-smi"
  t_stub gst-inspect-1.0 'exit 1'
  t_stub gst-launch-1.0 'exit 1'
  t_stub nproc 'echo 8'
  t_run GS_PROBE_CACHE="$T_TMP/gst-probes.env" -- 'bash "$GS_REPO/src/dev/capture-info.sh" h265'
  t_golden capture-info-h265-fallback "$(tool_text)"
}

golden_profile_capture() {
  t_case "nvidia: profile-capture with a cudaconvertscale capture and cs2"
  profile_stubs
  nvidia_smi_stub
  fake_proc gst gst-launch-1.0 -e ximagesrc use-damage=false '!' cudaupload '!' \
    cudaconvertscale '!' nvcudah264enc
  fake_proc cs2 /steamlib/game/bin/linuxsteamrt64/cs2 -steam
  t_run PG_GST_PATTERN='gst-launch-1.0.*ximagesrc' PG_CS2=1 -- \
    'bash "$GS_REPO/src/dev/profile-capture.sh" 1 1'
  t_golden profile-capture-cuda "$(tool_text)"

  t_case "nvidia: profile-capture with a CPU videoscale consumer, no cs2 and no nvidia-smi"
  profile_stubs
  fake_proc gst vkcapture-consumer --pipeline 'videoscale ! videoconvert ! x264enc'
  t_run PG_GST_PATTERN=vkcapture-consumer -- 'bash "$GS_REPO/src/dev/profile-capture.sh" 1 1'
  t_golden profile-capture-videoscale "$(tool_text)"

  t_case "nvidia: profile-capture with nothing running"
  profile_stubs
  nvidia_smi_stub
  t_run -- 'bash "$GS_REPO/src/dev/profile-capture.sh" 1 1'
  t_golden profile-capture-none "$(tool_text)"
}

golden_capture_info
golden_profile_capture
if t_capture_mode; then t_done; fi

t_done
