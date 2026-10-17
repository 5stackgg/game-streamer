# S3-U2: write_cs2_video_cfg (src/lib/cs2-options.sh) in live mode with an override JSON.
# The NVIDIA and unset outputs are goldens captured on the upstream commit, the written
# file included byte for byte; the AMD cases after the capture-mode line check the
# VendorID 4098 of S3 C12 (S3-D13).
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # the t_run script and the stub body expand in the child shell
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=lib/golden.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/golden.sh"

# write_cs2_video_cfg the way run-live.sh runs it, then the mode of the written file.
VIDEO='set -uo pipefail; . "$GS_REPO/src/lib/common.sh"; . "$LIB_DIR/cs2-options.sh"
write_cs2_video_cfg live
f="$CS2_DIR/game/csgo/cfg/cs2_video.txt"
if [ -e "$f" ]; then printf "mode %s\n" "$(stat -c %a "$f")"; fi'
OVERRIDE='{"setting.shaderquality":"1"}'

# video_case NAME: a case with a jq stub (ubuntu:24.04 has no jq). It answers the four jq
# calls of write_cs2_video_cfg for OVERRIDE: the validity check, the length (0 only for
# {}), the locked-key filter (it passes the r_low_latency value on) and the key and value
# lines, in the order jq prints them (the override, then r_low_latency).
video_case() {
  t_case "$1"
  t_stub jq '
in=$(cat)
case "$1" in
  -e) exit 0 ;;
  --argjson) printf "ll=%s\n" "$3" ;;
  -r)
    case "$2" in
      length) if [ "$in" = "{}" ]; then echo 0; else echo 1; fi ;;
      *) printf "setting.shaderquality\t1\nsetting.r_low_latency\t%s\n" "${in#ll=}" ;;
    esac
    ;;
esac'
}

# video_file: the written file plus a trailing x, so trailing newlines count.
video_file() {
  cat "$T_TMP/steamlib/steamapps/common/Counter-Strike Global Offensive/game/csgo/cfg/cs2_video.txt"
  printf x
}

video_text() {
  printf 'stdout:\n%s\nstderr:\n%s\nfile:\n%s\n' "$T_STDOUT" "$T_STDERR" "$(video_file)"
}

golden_video() {
  video_case "unset vendor: live with an override"
  t_run CS2_VIDEO_SETTINGS="$OVERRIDE" -- "$VIDEO"
  t_golden video-unset-live "$(video_text)"

  video_case "nvidia: live with an override"
  t_run GS_GPU_VENDOR=nvidia CS2_VIDEO_SETTINGS="$OVERRIDE" -- "$VIDEO"
  t_golden video-nvidia-live "$(video_text)"

  video_case "unset vendor: auto mode"
  t_run -- "$VIDEO"
  t_golden video-unset-auto "$(printf 'stdout:\n%s\nstderr:\n%s\n' "$T_STDOUT" "$T_STDERR")"
}

golden_video
if t_capture_mode; then t_done; fi

# The AMD cases (S3 C12, S3-D13): CS2 checks VendorID against the GPU, so the AMD file says
# 4098 (0x1002) where upstream's says 4318 (0x10de). Every other line matches the NVIDIA
# file, the file stays read-only, and no DeviceID line appears.

video_case "nvidia: the file the AMD case is compared with"
t_run GS_GPU_VENDOR=nvidia CS2_VIDEO_SETTINGS="$OVERRIDE" -- "$VIDEO"
nvidia_file="$(video_file)"

video_case "amd: live with an override"
t_run GS_GPU_VENDOR=amd CS2_VIDEO_SETTINGS="$OVERRIDE" -- "$VIDEO"
amd_file="$(video_file)"
assert_contains "$amd_file" "$(printf '\t"VendorID"\t\t"4098"')" "VendorID 4098"
assert_not_contains "$amd_file" '"4318"' "no NVIDIA VendorID left"
assert_not_contains "$amd_file" DeviceID "no DeviceID line"
assert_eq "$(printf '%s' "$nvidia_file" | sed 's/"4318"/"4098"/')" "$amd_file" \
  "only the VendorID differs from the NVIDIA file"
assert_contains "$T_STDOUT" 'mode 444' "read-only (0444)"
assert_contains "$T_STDOUT" \
  'wrote cs2_video.txt (mode=live, r_low_latency=2, overrides=2, read-only)' "upstream's log line"
assert_empty "$T_STDERR" "nothing on stderr"

video_case "amd: auto mode writes no file"
t_run GS_GPU_VENDOR=amd -- "$VIDEO"
assert_contains "$T_STDOUT" 'cs2_video.txt: auto mode (no overrides; cs2 will generate)' \
  "auto mode log line"
assert_no_file "$T_TMP/steamlib/steamapps/common/Counter-Strike Global Offensive/game/csgo/cfg/cs2_video.txt" \
  "no cs2_video.txt in auto mode"
assert_empty "$T_STDERR" "nothing on stderr"
t_done
