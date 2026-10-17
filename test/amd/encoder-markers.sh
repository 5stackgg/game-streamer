# S5-U4, harness half (S5-D4 option (c)): on AMD, the status=live report of run-live.sh,
# run-demo.sh outside batch mode and switch-match.sh carries one more argument,
# progress_stage=encoder:<element>, when encoder_caps holds encoder.live; nothing else
# changes.
#
# Each site is cut out of its flow file by anchor text that must match exactly one line,
# then evaluated after sourcing src/lib/common.sh, with start_capture stubbed and
# report_status writing its arguments, one per line, to $T_TMP/report.args. The NVIDIA
# goldens (GS_GPU_VENDOR unset) are captured on the upstream commit. The same cut works
# there and on the branch, where the site also calls gs_encoder_marker from common.sh, so
# golden_status_sites serves both modes.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # t_run scripts expand in the child shell
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=lib/golden.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/golden.sh"

# shellcheck disable=SC1003  # the anchor line ends in a literal backslash
RUN_LIVE_FIRST='start_capture "$MATCH_ID" "$FPS" "$VIDEO_KBPS" false 1 \'
SWITCH_FIRST='STREAM_ID="${OLD_MATCH_ID:-$MATCH_ID}"'
LIVE_STMT='report_status status=live'
DEMO_BATCH_LINE='  report_status status=live "playback_mode=demo"'
SITE_KEYS="run-live run-demo-live run-demo-batch switch-match"
ARGS=""

# site_block FILE FIRST STMT
# Prints FILE from the line FIRST (it must occur exactly once) through the end of the first
# statement at or after it whose first line starts with STMT; a statement ends at the first
# line that does not end in a backslash.
site_block() {
  local file="$1" first="$2" stmt="$3" line out="" state=0 n
  n=$(grep -c -x -F -- "$first" "$file")
  if [ "$n" != 1 ]; then
    echo "site_block: [$first] matched $n lines in $file" >&2
    return 1
  fi
  while IFS= read -r line; do
    if [ "$state" = 0 ]; then
      [ "$line" = "$first" ] || continue
      state=1
    fi
    out+="$line"$'\n'
    if [ "$state" = 1 ] && [[ "$line" == "$stmt"* ]]; then
      state=2
    fi
    if [ "$state" = 2 ] && [[ "$line" != *\\ ]]; then
      printf '%s' "$out"
      return 0
    fi
  done < "$file"
  echo "site_block: no [$stmt] statement after [$first] in $file" >&2
  return 1
}

# top_if_block FILE INNER
# Prints the if ... fi block, both lines at column 0, that holds the line INNER (it must
# occur exactly once in FILE).
top_if_block() {
  local file="$1" inner="$2" line buf="" in_if=0 found=0 n
  n=$(grep -c -x -F -- "$inner" "$file")
  if [ "$n" != 1 ]; then
    echo "top_if_block: [$inner] matched $n lines in $file" >&2
    return 1
  fi
  while IFS= read -r line; do
    case "$line" in
      'if '*)
        buf="$line"$'\n'
        in_if=1
        found=0
        continue
        ;;
    esac
    [ "$in_if" = 1 ] || continue
    buf+="$line"$'\n'
    [ "$line" = "$inner" ] && found=1
    if [ "$line" = 'fi' ]; then
      if [ "$found" = 1 ]; then
        printf '%s' "$buf"
        return 0
      fi
      in_if=0
      buf=""
    fi
  done < "$file"
  echo "top_if_block: no if block around [$inner] in $file" >&2
  return 1
}

# site_text KEY: prints the status=live site of KEY (run-live, run-demo-live,
# run-demo-batch or switch-match).
site_text() {
  case "$1" in
    run-live)
      site_block "$GS_REPO/src/flows/run-live.sh" "$RUN_LIVE_FIRST" "$LIVE_STMT" ;;
    run-demo-live | run-demo-batch)
      top_if_block "$GS_REPO/src/flows/run-demo.sh" "$DEMO_BATCH_LINE" ;;
    switch-match)
      site_block "$GS_REPO/src/flows/switch-match.sh" "$SWITCH_FIRST" "$LIVE_STMT" ;;
    *)
      echo "site_text: unknown site $1" >&2
      return 1 ;;
  esac
}

# site_run KEY [VAR=VALUE ...]
# Evaluates the site of KEY under set -uo pipefail with fixed inputs (CLIP_BATCH_MODE=1 for
# run-demo-batch) plus the pairs given. Sets ARGS to the report_status arguments, one per
# line. Fails the case and returns 1 only when the site cannot be cut out; a site that
# stops before report_status leaves ARGS empty, which the asserts catch.
site_run() {
  local key="$1"
  shift
  local -a pairs=(MEDIAMTX_SRT_BASE=srt://mediamtx.test:8890 MATCH_ID=match-1
    OLD_MATCH_ID=match-0 FPS=60 VIDEO_KBPS=12000 GS_PROBE_CACHE="$T_TMP/gst-probes.env")
  [ "$key" = run-demo-batch ] && pairs+=(CLIP_BATCH_MODE=1)
  ARGS=""
  if ! site_text "$key" > "$T_TMP/site.sh"; then
    _t_bad "cannot cut the $key site out of its flow file"
    return 1
  fi
  rm -f "$T_TMP/report.args"
  t_run "${pairs[@]}" "$@" -- 'set -uo pipefail
SCRIPT_TAG=site
. "$GS_REPO/src/lib/common.sh"
start_capture() { return 0; }
report_status() { printf "%s\n" "$@" >> "$T_TMP/report.args"; }
eval "$(cat "$T_TMP/site.sh")"'
  ARGS="$(cat "$T_TMP/report.args" 2>/dev/null)"
  return 0
}

golden_status_sites() {
  local key
  for key in $SITE_KEYS; do
    t_case "nvidia: the status=live arguments at the $key site"
    # A stale encoder.live never reaches a report without GS_GPU_VENDOR=amd.
    printf 'encoder.live=vah264enc\n' > "$LOG_DIR/encoder_caps"
    site_run "$key" || continue
    assert_rc 0 "the $key site runs"
    t_golden "$key" "$ARGS"
  done
}

golden_status_sites
if t_capture_mode; then t_done; fi

# AMD_ENV is the pod env of an AMD GPU job on the Radeon 8060S of f155ad35 (gfx1151, PCI ID
# 0x1002:0x1586), which amd_gpu adds to the fake sysfs; part 07's gs_gpu_env derives the
# same render node from it.
AMD_ENV=(GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:c6:00.0 GS_RENDER_NODE=/dev/dri/renderD128)
amd_gpu() {
  t_fake_gpu 0000:c6:00.0 0x1002 0x1586 0x038000 renderD128
}

# caps_lines PREFIX: the encoder_caps lines that start with PREFIX, in file order.
caps_lines() {
  local line out=""
  if [ -r "$LOG_DIR/encoder_caps" ]; then
    while IFS= read -r line; do
      [[ "$line" == "$1"* ]] && out+="$line"$'\n'
    done < "$LOG_DIR/encoder_caps"
  fi
  printf '%s' "${out%$'\n'}"
}

# lib_run [VAR=VALUE ...] -- CODE: runs CODE under set -uo pipefail after sourcing
# src/lib/common.sh, with a fresh probe cache. The script ends with true, so T_RC is 0
# unless the shell stopped early (an unbound variable under set -u).
lib_run() {
  local -a pairs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    pairs+=("$1")
    shift
  done
  t_run "${pairs[@]}" GS_PROBE_CACHE="$T_TMP/gst-probes.env" -- 'set -uo pipefail
SCRIPT_TAG=caps
. "$GS_REPO/src/lib/common.sh"
'"$2"'
true'
}

t_case "amd: gs_encoder_status records encoder.<mode> for live, clip and inline"
amd_gpu
lib_run "${AMD_ENV[@]}" -- '
gs_encoder_status live h264 h264 "vah264enc rate-control=vbr target-usage=4" "videorate ! vapostproc"
gs_encoder_status clip h265 h265 "vah265enc rate-control=cqp" "videorate ! vapostproc"
gs_encoder_status inline h265 h264 h264_vaapi "" trial-fail'
assert_rc 0 "the three calls run"
assert_eq $'encoder.live=vah264enc\nencoder.clip=vah265enc\nencoder.inline=h264_vaapi' \
  "$(caps_lines encoder.)" "one encoder.<mode> line per call, the first word of the encoder string"

t_case "amd: a second live call appends a second encoder.live line"
amd_gpu
lib_run "${AMD_ENV[@]}" -- '
gs_encoder_status live h264 h264 "x264enc speed-preset=veryfast" "videorate ! videoscale"
gs_encoder_status live h264 h264 "vah264enc rate-control=vbr" "videorate ! vapostproc"
_gs_caps_get encoder.live > "$T_TMP/encoder.live"'
assert_rc 0 "the two calls run"
assert_eq $'encoder.live=x264enc\nencoder.live=vah264enc' "$(caps_lines encoder.)" "both live calls are recorded"
assert_eq vah264enc "$(cat "$T_TMP/encoder.live")" "_gs_caps_get encoder.live gives the last one"

t_case "amd: an empty encoder string writes no encoder.<mode> line"
amd_gpu
lib_run "${AMD_ENV[@]}" -- 'gs_encoder_status inline h264 h264 "" "" ok'
assert_rc 0 "the call runs"
assert_empty "$(caps_lines encoder.)" "no encoder.inline line"

NV_CALLS='
gs_encoder_status live h264 h264 "nvcudah264enc bitrate=12000" "cudaupload ! cudaconvertscale"
gs_encoder_status clip h264 h264 "nvcudah264enc bitrate=12000" "cudaupload ! cudaconvertscale"
gs_encoder_status inline h264 h264 h264_nvenc ""'

t_case "nvidia: gs_encoder_status writes no encoder_caps (GS_GPU_VENDOR unset)"
lib_run -- "$NV_CALLS"
assert_rc 0 "the calls run"
assert_no_file "$LOG_DIR/encoder_caps" "encoder_caps is never written on NVIDIA"

t_case "nvidia: gs_encoder_status writes no encoder_caps (GS_GPU_VENDOR=nvidia)"
lib_run GS_GPU_VENDOR=nvidia -- "$NV_CALLS"
assert_rc 0 "the calls run"
assert_no_file "$LOG_DIR/encoder_caps" "encoder_caps is never written on NVIDIA"


# The encoder marker at the status=live sites (S5-U4). golden_args KEY prints the NVIDIA
# arguments of a site as captured on the upstream commit; the AMD cases expect them plus,
# at most, one last argument.
golden_args() {
  cat "$GS_GOLDEN_DIR/${T_FILE%.sh}/$1.txt"
}
LIVE_SITES="run-live run-demo-live switch-match"

t_case "amd: the run-live status=live report names the newest live encoder"
amd_gpu
printf 'encoder.live=x264enc\nh264=va:vah264enc\nencoder.live=vah264enc\n' > "$LOG_DIR/encoder_caps"
site_run run-live "${AMD_ENV[@]}"
assert_rc 0 "the run-live site runs"
assert_eq "$(golden_args run-live)"$'\n'"progress_stage=encoder:vah264enc" "$ARGS" \
  "the NVIDIA arguments plus progress_stage=encoder:vah264enc"

t_case "amd: the run-demo status=live report names the live encoder"
amd_gpu
printf 'encoder.live=vah265enc\n' > "$LOG_DIR/encoder_caps"
site_run run-demo-live "${AMD_ENV[@]}"
assert_rc 0 "the run-demo site runs"
assert_eq "$(golden_args run-demo-live)"$'\n'"progress_stage=encoder:vah265enc" "$ARGS" \
  "the NVIDIA arguments plus progress_stage=encoder:vah265enc"

t_case "amd: the switch-match status=live report names the live encoder"
amd_gpu
printf 'encoder.live=x264enc\n' > "$LOG_DIR/encoder_caps"
site_run switch-match "${AMD_ENV[@]}"
assert_rc 0 "the switch-match site runs"
assert_eq "$(golden_args switch-match)"$'\n'"progress_stage=encoder:x264enc" "$ARGS" \
  "the NVIDIA arguments plus progress_stage=encoder:x264enc"

for key in $LIVE_SITES; do
  t_case "amd: no marker at the $key site when encoder_caps has no encoder.live"
  amd_gpu
  printf 'h264=va:vah264enc\nencoder.clip=vah264enc\nencoder.inline=h264_vaapi\n' \
    > "$LOG_DIR/encoder_caps"
  site_run "$key" "${AMD_ENV[@]}"
  assert_rc 0 "the $key site runs"
  assert_eq "$(golden_args "$key")" "$ARGS" "the NVIDIA arguments, nothing more"

  t_case "amd: no marker at the $key site when nothing wrote encoder_caps"
  amd_gpu
  site_run "$key" "${AMD_ENV[@]}"
  assert_rc 0 "the $key site runs"
  assert_eq "$(golden_args "$key")" "$ARGS" "the NVIDIA arguments, nothing more"

  t_case "nvidia: no marker at the $key site with GS_GPU_VENDOR=nvidia and a stale encoder.live"
  printf 'encoder.live=vah264enc\n' > "$LOG_DIR/encoder_caps"
  site_run "$key" GS_GPU_VENDOR=nvidia
  assert_rc 0 "the $key site runs"
  assert_eq "$(golden_args "$key")" "$ARGS" "the NVIDIA arguments, nothing more"
done

# Batch mode (CLIP_BATCH_MODE=1 with CLIP_BATCH_JOBS): the batch branch of run-demo.sh
# keeps its arguments. Through the real report_status of src/lib/status-reporter.sh, a
# status=live report sends no booting tick, while a marker would be folded into one for
# every job (the control case), which is why that branch gets none.
BATCH_JOBS='[{"job_id":"job-1","token":"token-1"}]'

# batch_stubs: node answers the two clip-helpers calls of a batch broadcast for one job
# (jobs-credentials reads the CLIP_BATCH_JOBS that report_status pipes in), and curl
# records the body it would post.
batch_stubs() {
  t_stub node 'case "${2:-}" in
  jobs-credentials) cat > /dev/null; printf "job-1\ttoken-1\n" ;;
  status-body) shift 2; printf "%s" "$*" ;;
esac'
  t_stub curl
}

# batch_run CODE: runs CODE on AMD in batch mode under set -uo pipefail, after sourcing
# src/lib/common.sh and src/lib/status-reporter.sh, with start_capture stubbed.
batch_run() {
  t_run "${AMD_ENV[@]}" CLIP_BATCH_MODE=1 CLIP_BATCH_JOBS="$BATCH_JOBS" MATCH_ID=match-1 \
    MEDIAMTX_SRT_BASE=srt://mediamtx.test:8890 FPS=60 VIDEO_KBPS=12000 \
    GS_PROBE_CACHE="$T_TMP/gst-probes.env" -- 'set -uo pipefail
SCRIPT_TAG=site
. "$GS_REPO/src/lib/common.sh"
. "$GS_REPO/src/lib/status-reporter.sh"
start_capture() { return 0; }
'"$1"'
true'
}

t_case "amd: the batch branch of run-demo.sh gets no marker"
amd_gpu
printf 'encoder.live=vah264enc\n' > "$LOG_DIR/encoder_caps"
site_run run-demo-batch "${AMD_ENV[@]}" CLIP_BATCH_JOBS="$BATCH_JOBS"
assert_rc 0 "the batch site runs"
assert_eq "$(golden_args run-demo-batch)" "$ARGS" "the NVIDIA arguments, nothing more"

t_case "amd: in batch mode the real report_status sends no booting tick with encoder:"
amd_gpu
batch_stubs
printf 'encoder.live=vah264enc\n' > "$LOG_DIR/encoder_caps"
if site_text run-demo-batch > "$T_TMP/site.sh"; then
  batch_run 'eval "$(cat "$T_TMP/site.sh")"'
  assert_rc 0 "the batch site runs"
  assert_match '^live[|]' "$(cat "$LOG_DIR/status.last" 2>/dev/null)" \
    "the real report_status recorded status=live"
  assert_not_contains "$(t_calls curl)" "encoder:" "no posted body names the encoder"
else
  _t_bad "cannot cut the run-demo-batch site out of run-demo.sh"
fi

t_case "control: in batch mode a marker reaches every job as a booting tick"
amd_gpu
batch_stubs
batch_run 'report_status status=live "playback_mode=demo" "progress_stage=encoder:vah264enc"'
assert_rc 0 "report_status runs"
assert_contains "$(t_calls curl)" "boot_stage=live:encoder:vah264enc" \
  "broadcast_batch_status folds the marker into the booting tick it posts"


for vendor in nvidia amd; do
  for key in $LIVE_SITES; do
    t_case "$vendor CPU record at the $key status site"
    : > "$LOG_DIR/live-cpu-encode"
    printf 'encoder.live=vah265enc\n' > "$LOG_DIR/encoder_caps"
    site_run "$key" GS_GPU_VENDOR="$vendor"
    assert_rc 0 'actual status site runs with a CPU record'
    assert_eq "$(golden_args "$key")"$'\n'progress_stage=encoder:x264enc "$ARGS" \
      'existing arguments plus exactly one CPU tag'
  done
done

t_done
