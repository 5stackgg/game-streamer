# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # unit scripts expand in their clean child shell
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

for vendor in nvidia amd; do
  for state in gpu cpu empty fail; do
    t_case "$vendor actual-success CPU record: $state"
    t_run GS_GPU_VENDOR="$vendor" RECORD_STATE="$state" -- '
set -uo pipefail
. "$GS_REPO/src/lib/common.sh"
. "$GS_REPO/src/lib/stream.sh"
[ "$RECORD_STATE" = cpu ] || : > "$LOG_DIR/live-cpu-encode"
_start_capture_once() {
  case "$RECORD_STATE" in
    gpu) GS_LAST_CAPTURE_ENC=nvcudah264enc ;;
    cpu) GS_LAST_CAPTURE_ENC="x264enc speed-preset=veryfast" ;;
    empty) GS_LAST_CAPTURE_ENC="" ;;
    fail) GS_LAST_CAPTURE_ENC=""; return 2 ;;
  esac
}
rc=0; start_capture session 60 8000 false 1 || rc=$?
printf "rc=%s record=%s\n" "$rc" "$(test -e "$LOG_DIR/live-cpu-encode" && echo 1 || echo 0)"'
    expected=1; rc=0
    [ "$state" != gpu ] || expected=0
    [ "$state" != fail ] || rc=2
    assert_eq 0 "$T_RC" 'wrapper returns to the caller'
    assert_eq "rc=$rc record=$expected" "$T_STDOUT" 'only actual successful new encoder changes record'
  done
  for cpu in 0 1; do
    t_case "$vendor marker with CPU record=$cpu"
    [ "$cpu" != 1 ] || : > "$LOG_DIR/live-cpu-encode"
    printf 'encoder.live=vah265enc\n' > "$LOG_DIR/encoder_caps"
    t_run GS_GPU_VENDOR="$vendor" -- '
set -uo pipefail
. "$GS_REPO/src/lib/common.sh"
gs_encoder_marker
printf "argc=%s\n" "${#GS_ENCODER_MARKER[@]}"
printf "%s\n" "${GS_ENCODER_MARKER[@]}"'
    assert_eq 0 "$T_RC" 'actual helper completes'
    if [ "$cpu" = 1 ]; then
      assert_eq $'argc=1\nprogress_stage=encoder:x264enc' "$T_STDOUT" 'CPU record wins on either vendor'
    elif [ "$vendor" = amd ]; then
      assert_eq $'argc=1\nprogress_stage=encoder:vah265enc' "$T_STDOUT" 'AMD GPU keeps existing live key'
    else
      assert_eq argc=0 "$T_STDOUT" 'NVIDIA GPU ignores stale AMD key'
    fi
  done
done

# Extract the real supervisor restart block, excluding its enclosing if terminator.
# Only external lifecycle/report boundaries are stubs; comparison and call placement
# come from run-live.sh, not a copied test implementation.
for scenario in same changed file-already-cpu failed empty; do
  t_case "supervisor encoder change: $scenario"
  awk '
    index($0,"    warn \"live capture down") == 1 {n++; on=1}
    on && $0 == "  fi" {on=0; done++}
    on {print}
    END {exit !(n==1 && done==1)}
  ' "$GS_REPO/src/flows/run-live.sh" > "$T_TMP/restart.sh"
  t_run RECORD_SCENARIO="$scenario" GS_GPU_VENDOR=nvidia MATCH_ID=match-1 MEDIAMTX_SRT_BASE=srt://media -- '
set -uo pipefail
. "$GS_REPO/src/lib/common.sh"
GS_LAST_CAPTURE_ENC="nvcudah264enc bitrate=8000"
[ "$RECORD_SCENARIO" != file-already-cpu ] || : > "$LOG_DIR/live-cpu-encode"
restart_capture() {
  case "$RECORD_SCENARIO" in
    same) GS_LAST_CAPTURE_ENC="nvcudah264enc bitrate=9000" ;;
    changed|file-already-cpu) GS_LAST_CAPTURE_ENC="x264enc bitrate=8000"; : > "$LOG_DIR/live-cpu-encode" ;;
    failed) GS_LAST_CAPTURE_ENC=x264enc; return 1 ;;
    empty) GS_LAST_CAPTURE_ENC="" ;;
  esac
}
report_status() { printf "%s\n" "$@" >> "$T_TMP/reports"; }
. "$T_TMP/restart.sh"
true'
  assert_eq 0 "$T_RC" 'actual supervisor branch reaches next iteration'
  if [ "$scenario" = changed ] || [ "$scenario" = file-already-cpu ]; then
    assert_eq $'status=live\nstream_url=srt://media?streamid=publish:match-1\nprogress_stage=encoder:x264enc' "$(cat "$T_TMP/reports" 2>/dev/null)" 'one changed-encoder report preserves URL and adds CPU tag'
  else
    assert_no_file "$T_TMP/reports" 'same, failed and unresolved restarts emit no report'
  fi
done

t_case 'on-demand capture restart sends no status report'
t_run -- '
set -uo pipefail
. "$GS_REPO/src/lib/common.sh"
. "$GS_REPO/src/lib/stream.sh"
stop_capture() { return 0; }
sleep() { return 0; }
_start_capture_once() { GS_LAST_CAPTURE_ENC="x264enc bitrate=8000"; }
report_status() { printf "%s\n" "$@" >> "$T_TMP/reports"; }
printf "session\n60\n8000\nfalse\n1\n" > "$LOG_DIR/capture-session.args"
restart_capture session'
assert_eq 0 "$T_RC" 'real restart path completes'
assert_no_file "$T_TMP/reports" 'report belongs only to live supervisor'
assert_eq 1 "$(test -e "$LOG_DIR/live-cpu-encode" && echo 1 || echo 0)" 'on-demand restart still updates capture record'

t_case 'switch-match uses real status reporter mute gate'
: > "$LOG_DIR/live-cpu-encode"
t_run MATCH_ID=match-1 OLD_MATCH_ID=match-0 MEDIAMTX_SRT_BASE=srt://media -- '
set -uo pipefail
. "$GS_REPO/src/lib/common.sh"
. "$GS_REPO/src/lib/status-reporter.sh"
gs_encoder_marker
report_status status=live "stream_url=${MEDIAMTX_SRT_BASE}?streamid=publish:${OLD_MATCH_ID}" "${GS_ENCODER_MARKER[@]}"'
assert_eq 0 "$T_RC" 'unconfigured status destination remains muted'
assert_no_file "$LOG_DIR/status.last" 'CPU marker does not bypass existing reporter gate'
assert_no_file "$LOG_DIR/status.state" 'no state is emitted without a destination'

t_done
