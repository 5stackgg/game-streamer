# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # these scripts expand only in t_run's clean child
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/encode-sites.sh"

# Stub captures are the S7-U5 boundary. The real mode helper and public wrappers
# run in the calling shell; neither an attempt nor a stop is a subshell.
for kind in live clip; do
  for scenario in retry retry-fails gpu cpu fallback software unresolved success empty-success rc2; do
    t_case "$kind wrapper: $scenario"
    first_enc=nvcudah264enc; first_rc=1; second_rc=0; mode=auto
    expected_rc=0; expected_attempts=2; expected_marker=1; expected_stops=1
    expected_last=x264enc; expected_picks=unset/unset
    case "$scenario" in
      retry) ;;
      retry-fails) second_rc=1; expected_rc=1; expected_marker=0 ;;
      *)
        expected_attempts=1; expected_marker=0; expected_stops=0
        expected_rc=1; expected_last=nvcudah264enc
        expected_picks=nvcudah264enc/nvcudah265enc
        case "$scenario" in
          gpu) mode=gpu ;;
          cpu) mode=cpu; first_enc=x264enc; expected_last=x264enc ;;
          fallback) first_enc=x264enc; expected_last=x264enc; expected_picks=unset/unset ;;
          software) first_enc=x264enc; expected_last=x264enc ;;
          unresolved) first_enc=''; expected_last='' ;;
          success) first_rc=0; expected_rc=0 ;;
          empty-success) first_enc=''; first_rc=0; expected_last=''; expected_rc=0 ;;
          rc2) first_rc=2; expected_rc=2 ;;
        esac
        ;;
    esac
    t_run GS_VIDEO_ENCODER="$mode" CF_KIND="$kind" CF_FIRST_ENC="$first_enc" \
      CF_FIRST_RC="$first_rc" CF_SECOND_RC="$second_rc" CF_SCENARIO="$scenario" \
      GS_NVENC_PICK=nvcudah264enc GS_NVENC_PICK_H265=nvcudah265enc -- '
set -uo pipefail
. "$GS_REPO/src/lib/common.sh"
. "$GS_REPO/src/lib/stream.sh"
. "$GS_REPO/src/lib/clip-capture.sh"
declare -F _start_capture_once >/dev/null || exit 3
declare -F _start_clip_capture_once >/dev/null || exit 3
CF_N=0
[ "$CF_SCENARIO" != fallback ] || : > "$LOG_DIR/cpu-fallback"
cf_marker() { if [ -e "$LOG_DIR/cpu-fallback" ]; then printf 1; else printf 0; fi; }
cf_attempt() {
  CF_N=$((CF_N+1))
  local rc
  if [ "$CF_N" = 1 ]; then GS_LAST_CAPTURE_ENC="$CF_FIRST_ENC"; rc="$CF_FIRST_RC"
  else GS_LAST_CAPTURE_ENC=x264enc; rc="$CF_SECOND_RC"; fi
  printf "attempt=%s marker=%s picks=%s/%s argc=%s\n" "$CF_N" "$(cf_marker)" \
    "${GS_NVENC_PICK-unset}" "${GS_NVENC_PICK_H265-unset}" "$#" >> "$T_TMP/trace"
  return "$rc"
}
_start_capture_once() { cf_attempt "$@"; }
_start_clip_capture_once() { cf_attempt "$@"; }
cf_stop() { printf "stop marker=%s picks=%s/%s argc=%s\n" "$(cf_marker)" \
  "${GS_NVENC_PICK-unset}" "${GS_NVENC_PICK_H265-unset}" "$#" >> "$T_TMP/trace"; }
stop_capture() { cf_stop "$@"; }
stop_clip_capture() { cf_stop "$@"; }
rc=0
if [ "$CF_KIND" = live ]; then start_capture session 60 8000 true 0 || rc=$?
else start_clip_capture "$T_TMP/out.mp4" 60 16000 0 || rc=$?; fi
printf "rc=%s attempts=%s marker=%s last=%s picks=%s/%s\n" "$rc" "$CF_N" "$(cf_marker)" \
  "${GS_LAST_CAPTURE_ENC:-}" "${GS_NVENC_PICK-unset}" "${GS_NVENC_PICK_H265-unset}"'
    assert_eq 0 "$T_RC" 'wrapper test reaches the result snapshot'
    assert_eq "rc=$expected_rc attempts=$expected_attempts marker=$expected_marker last=$expected_last picks=$expected_picks" \
      "$T_STDOUT" 'bounded retry and cleanup result'
    trace=$(cat "$T_TMP/trace" 2>/dev/null || true)
    assert_eq "$expected_stops" "$(grep -c '^stop ' <<< "$trace" || true)" 'one stop only before a CPU retry'
    if [ "$expected_attempts" = 2 ]; then
      assert_contains "$trace" 'stop marker=1 picks=nvcudah264enc/nvcudah265enc' 'marker precedes stop; picks are cleared after it'
      assert_contains "$trace" 'attempt=2 marker=1 picks=unset/unset' 'CPU attempt sees marker and no stale picks'
      assert_contains "$T_STDERR" 'capture: nvcudah264enc failed to start, retrying on the CPU (video_encoder=auto)' 'retry warning names the failed element'
    else
      assert_not_contains "$T_STDERR" 'retrying on the CPU' 'no unsupported retry'
    fi
    if [ "$scenario" = gpu ]; then
      assert_contains "$T_STDERR" "video_encoder=gpu:" "GPU-only start failure names the setting"
    fi
    if [ "$kind" = live ]; then argc=5; else argc=4; fi
    assert_contains "$trace" "argc=$argc" 'capture arguments are forwarded unchanged'
  done
done

# Keep the actual clip dispatch body: a GPU attempt must exhaust both methods
# before the wrapper starts the CPU attempt. Only the two capture methods are stubs.
t_case 'clip dispatch: GPU vk, GPU gst, CPU vk, CPU gst'
t_stub vkcapture-consumer 'exit 0'
t_run -- '
set -uo pipefail
. "$GS_REPO/src/lib/common.sh"
. "$GS_REPO/src/lib/clip-capture.sh"
declare -F _start_clip_capture_once >/dev/null || exit 3
cf_method() {
  local method="$1" mode
  mode=$(gs_video_encoder_mode)
  if [ "$mode" = auto ]; then GS_LAST_CAPTURE_ENC=nvcudah264enc; mode=gpu
  else GS_LAST_CAPTURE_ENC=x264enc; mode=cpu; fi
  printf "%s:%s\n" "$mode" "$method" >> "$T_TMP/order"
  [ "$mode:$method" = cpu:gst ]
}
_start_clip_capture_vkcapture() { cf_method vk; }
_start_clip_capture_gst() { cf_method gst; }
stop_clip_capture() { printf "stop\n" >> "$T_TMP/order"; }
start_clip_capture "$T_TMP/out.mp4" 60 16000 0'
assert_eq 0 "$T_RC" 'last CPU method succeeds'
assert_eq $'gpu:vk\ngpu:gst\nstop\ncpu:vk\ncpu:gst' "$(cat "$T_TMP/order" 2>/dev/null)" 'actual dispatch order across the two attempts'
assert_eq 1 "$(test -e "$LOG_DIR/cpu-fallback" && echo 1 || echo 0)" 'successful CPU attempt keeps pod policy'

# Real producers: actual live, vkcapture and ximagesrc functions with only the
# existing external command stubs. Both H.264 and HEVC must store their resolved
# encoder in the caller before any spawn failure can be returned.
for site in live vk gst; do
  for codec in h264 h265; do
    es_case "capture encoder producer: $site $codec"
    if [ "$site" = live ]; then
      es_sh stream.sh LIVE_VIDEO_CODEC="$codec" -- '
GS_LAST_CAPTURE_ENC=stale
start_capture session 60 8000 true 0
printf "rc=%s last=%s\n" "$?" "${GS_LAST_CAPTURE_ENC:-}"'
    else
      method=vkcapture; [ "$site" != gst ] || method=ximagesrc
      es_sh clip-capture.sh CLIP_OUTPUT_DIMS=1920x1080 CLIP_VIDEO_CODEC="$codec" CLIP_CAPTURE_METHOD="$method" -- '
GS_LAST_CAPTURE_ENC=stale
start_clip_capture "$T_TMP/out.mp4" 60 16000 0
printf "rc=%s last=%s\n" "$?" "${GS_LAST_CAPTURE_ENC:-}"'
    fi
    assert_eq 0 "$T_RC" "real capture caller exits cleanly: $T_STDERR"
    expected=nvcudah264enc; [ "$codec" != h265 ] || expected=nvcudah265enc
    assert_contains "$T_STDOUT" "rc=0 last=$expected " 'actual encoder fragment reaches the parent'
  done
done

t_done
