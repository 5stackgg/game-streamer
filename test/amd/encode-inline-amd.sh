# S4-U11 and the inline site of S4-U9: src/lib/inline-clip-render.sh on AMD, run end to end
# with the stubs of lib/inline-driver.sh, no goldens. Covers the four encode sites on
# h264_vaapi and hevc_vaapi, the one-frame ffmpeg trials and their encoder_caps keys, the
# libx264 fallbacks with their reasons, the h264_vaapi retry of ffmpeg_venc at each site,
# the S4 C32 guards on that retry, and the one ENCODER-CAPS line of the inline call.
#
# The render shapes a to d are those of encode-inline.sh. The AMD renders select the fake
# GPU of amd_case (0000:c6:00.0, renderD128), set the gst picks to va:vah264enc and
# va:vah265enc, and get a vainfo stub that names gfx1151; the gst trials of the VA helpers
# pass through the driver's gst-launch-1.0 stub. The retry cases compare a retry's argv
# with the call the CLIP_FINAL_ENCODER=x264 render of the same shape makes at that site.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2119  # inline_render takes optional VAR=VALUE pairs
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=lib/golden.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/golden.sh"
# shellcheck source=lib/inline-driver.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/inline-driver.sh"

TWO_SEGMENTS="$(inline_segments 2)"
SHAPE=()

# shape a|b|c|d: sets SHAPE to the inline_render arguments of that render shape.
shape() {
  case "$1" in
    a) SHAPE=() ;;
    b) SHAPE=(CLIP_SEGMENTS="$TWO_SEGMENTS") ;;
    c) SHAPE=(CLIP_SEGMENTS="$TWO_SEGMENTS" CLIP_MAX_FUSED_SEGMENTS=6) ;;
    d) SHAPE=(CLIP_SEGMENTS="$TWO_SEGMENTS" CLIP_DISABLE_OUTRO=1 INLINE_COPY_FAIL=1) ;;
  esac
}

# The sites each shape reaches, in call order (inline_sites).
declare -A SHAPE_SITES=([a]="1 2 copy" [b]="1 3" [c]="3" [d]="1 copy 4")

NODE=/dev/dri/renderD128
HW="-init_hw_device vaapi=gsva:$NODE -filter_hw_device gsva"
VA_H264="-c:v h264_vaapi -rc_mode VBR -b:v 9M -maxrate 14M -bufsize 18M -compression_level 5 -bf 0 -g 120 -profile:v high -level 4.2"
VA_HEVC="-c:v hevc_vaapi -rc_mode CQP -qp 24 -compression_level 5 -bf 0 -g 120 -profile:v main -tag:v hvc1"
X264="-c:v libx264 -preset veryfast -crf 22 -pix_fmt yuv420p -profile:v high -level 4.2"
TRIAL="-hide_banner -loglevel error $HW -f lavfi -i testsrc2=size=1920x1080:rate=60 -frames:v 1 -vf format=nv12,hwupload"
KEY_H264=trial.ffmpeg.h264_vaapi.1920x1080
KEY_HEVC=trial.ffmpeg.hevc_vaapi.1920x1080
WARN_RETRY="WARN final encode: h264_vaapi failed, retrying with libx264"
FINAL_VA="final encode: h264_vaapi VBR 9M (max 14M) on $NODE"
FINAL_X264="final encode: libx264 veryfast crf 22 (h264_vaapi unavailable or CLIP_FINAL_ENCODER=x264, reason="

# The AMD selection of amd_case's fake GPU, with the VA gst picks.
AMD=(GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS=0000:c6:00.0 GS_RENDER_NODE="$NODE"
  GS_NVENC_PICK=va:vah264enc GS_NVENC_PICK_H265=va:vah265enc)

# amd_case NAME: inline_case, then a Radeon 8060S (gfx1151) at 0000:c6:00.0 with renderD128
# in the fake sysfs, and a vainfo stub.
amd_case() {
  inline_case "$1"
  t_fake_gpu 0000:c6:00.0 0x1002 0x1586 0x038000 renderD128
  t_stub vainfo 'printf "%s\n" "vainfo: VA-API version: 1.20 (libva 2.20.0)" \
  "vainfo: Driver version: Mesa Gallium driver 25.2.8-0ubuntu0.24.04.2 for AMD Radeon Graphics (radeonsi, gfx1151, ACO, DRM 3.64, 7.0.0-31-generic)"'
}

# amd_render [VAR=VALUE ...]: inline_render with the AMD selection (the pairs given
# override it), then checks that no NVENC test encode and no 'ffmpeg -encoders' probe ran.
amd_render() {
  inline_render "${AMD[@]}" "$@"
  assert_not_contains "$(cat "$T_TMP/inline/ffmpeg.argv" 2>/dev/null)" nvenc "no NVENC call"
  assert_empty "$(inline_calls encoders)" "no ffmpeg -encoders probe"
}

# caps KEY: the value of KEY in this case's encoder_caps (the last line wins).
caps() {
  awk -F= -v k="$1" '$1 == k { v = substr($0, length(k) + 2) } END { printf "%s", v }' \
    "$LOG_DIR/encoder_caps" 2>/dev/null
}

# caps_lines: the ENCODER-CAPS lines of the inline mode in the last render's log.
caps_lines() {
  grep 'ENCODER-CAPS: mode=inline ' <<<"$INLINE_LOG" || true
}

# caps_re REQUESTED ACTUAL ENCODER REASON: the regex of an inline ENCODER-CAPS line with
# all nine fields.
caps_re() {
  printf 'ENCODER-CAPS: mode=inline requested=%s actual=%s encoder=%s device=[^ ]* gfx=[^ ]* device_id=[^ ]* scaler=[^ ]* reason=%s$' \
    "$1" "$2" "$3" "$4"
}

# check_va SITE ENCODER_ARGS: the first call at SITE opens the VA device before its first
# -i, carries ENCODER_ARGS and ends its video filters with hwupload.
check_va() {
  local site="$1" enc="$2" call
  call=$(inline_calls "$site" | head -n 1)
  assert_contains "${call%% -i *}" " $HW" "site $site: VA device before the first -i"
  case "$site" in
    1)
      assert_contains "$call" \
        "overlay=0:0:eof_action=pass:format=auto,format=nv12,hwupload[vout] -map [vout] -map 0:a -c:a aac -b:a 192k $enc " \
        "site 1: hwupload ends the graph, encoder args"
      ;;
    3)
      assert_contains "$call" "[v][a];[v]format=nv12,hwupload[vhw] -map [vhw] -map [a] $enc " \
        "site 3: hwupload ends the graph, [vhw] mapped, encoder args"
      ;;
    *)
      assert_contains "$call" " -vf format=nv12,hwupload $enc " \
        "site $site: hwupload is the only video filter, encoder args"
      ;;
  esac
}

# check_no_va MESSAGE: no call of the last render opens a VA device or uploads, the
# one-frame trials aside.
check_no_va() {
  local argv="" site
  for site in encoders 1 2 3 4 copy other; do
    argv+="$(inline_calls "$site")"$'\n'
  done
  assert_not_contains "$argv" "-init_hw_device" "$1: no -init_hw_device"
  assert_not_contains "$argv" "hwupload" "$1: no hwupload"
}

# S4-U11: the VA encoder at every site, for both codecs and the four shapes; S4-U9, inline
# site: one ENCODER-CAPS line per render, logged with log.
for codec in h264 h265; do
  enc="$VA_H264" act_enc=h264_vaapi
  if [ "$codec" = h265 ]; then enc="$VA_HEVC" act_enc=hevc_vaapi; fi
  for s in a b c d; do
    amd_case "AMD $codec request, shape $s: $act_enc at every site"
    shape "$s"
    amd_render CLIP_VIDEO_CODEC="$codec" "${SHAPE[@]}"
    assert_eq 0 "$INLINE_RC" "render exits 0"
    assert_eq "${SHAPE_SITES[$s]}" "$(inline_sites)" "sites"
    read -ra sites <<<"${SHAPE_SITES[$s]}"
    for site in "${sites[@]}"; do
      [ "$site" = copy ] || check_va "$site" "$enc"
    done
    assert_contains "$INLINE_LOG" "$FINAL_VA" "final encode line"
    assert_eq ok "$(caps "$KEY_H264")" "h264_vaapi trial cached as ok"
    assert_eq 1 "$(caps_lines | grep -c .)" "one inline ENCODER-CAPS line"
    assert_match "$(caps_re "$codec" "$codec" "$act_enc" ok)" "$(caps_lines)" "ENCODER-CAPS fields"
    assert_not_contains "$(caps_lines)" "WARN" "ENCODER-CAPS logged with log"
    if [ "$codec" = h265 ]; then
      assert_eq "$TRIAL $VA_H264 -f null -"$'\n'"$TRIAL $VA_HEVC -f null -" "$(inline_calls trial)" \
        "the h264_vaapi trial, then the hevc_vaapi trial"
      assert_eq ok "$(caps "$KEY_HEVC")" "hevc_vaapi trial cached as ok"
      assert_contains "$INLINE_LOG" "h265 probe: gstreamer VA-API HEVC OK (pick=va:vah265enc)" "gst probe line"
      assert_contains "$INLINE_LOG" "h265 probe: ffmpeg hevc_vaapi OK on $NODE" "ffmpeg probe line"
      assert_contains "$INLINE_LOG" "h265 selected for this render" "h265 choice"
    else
      assert_eq "$TRIAL $VA_H264 -f null -" "$(inline_calls trial)" "one h264_vaapi trial"
    fi
    if [ "$codec$s" = h264a ]; then
      assert_contains "$(caps_lines)" " device=$NODE " "ENCODER-CAPS device"
      assert_contains "$INLINE_LOG" "  concat: stream-copy OK" "stream-copy line"
      assert_match '^outro-[0-9a-f]{12}\.mp4$' "$(inline_cached)" "one cached outro, no staging file"
    fi
  done
done

# CLIP_FINAL_ENCODER=x264 on AMD: libx264 everywhere, no trial, no VA device. These renders
# also give the libx264 call of each site and shape that a retry must match.
declare -A X264_CALL=()
for s in a b c d; do
  amd_case "AMD, CLIP_FINAL_ENCODER=x264, shape $s"
  shape "$s"
  amd_render CLIP_FINAL_ENCODER=x264 "${SHAPE[@]}"
  assert_eq 0 "$INLINE_RC" "render exits 0"
  assert_eq "${SHAPE_SITES[$s]}" "$(inline_sites)" "sites"
  assert_contains "$INLINE_LOG" "${FINAL_X264}forced-x264)" "final encode line"
  assert_empty "$(inline_calls trial)" "no trial"
  check_no_va "x264"
  read -ra sites <<<"${SHAPE_SITES[$s]}"
  for site in "${sites[@]}"; do
    [ "$site" = copy ] && continue
    X264_CALL[$site$s]=$(inline_calls "$site" | head -n 1)
    assert_contains "${X264_CALL[$site$s]}" " $X264 " "site $site: libx264"
  done
  assert_match "$(caps_re h264 h264 libx264 forced-x264)" "$(caps_lines)" "ENCODER-CAPS fields"
  assert_contains "$(caps_lines)" "WARN: ENCODER-CAPS" "ENCODER-CAPS logged with warn"
done

# The libx264 fallbacks and their reasons.
inline_case "AMD with no render node"
amd_render GS_GPU_PCI_ADDRESS= GS_RENDER_NODE= GS_NVENC_PICK=x264enc GS_NVENC_PICK_H265=none
assert_eq 0 "$INLINE_RC" "render exits 0"
assert_contains "$INLINE_LOG" "${FINAL_X264}no-render-node)" "final encode line"
assert_empty "$(inline_calls trial)" "no trial"
check_no_va "no render node"
assert_match "$(caps_re h264 h264 libx264 no-render-node)" "$(caps_lines)" "ENCODER-CAPS fields"

amd_case "AMD, the gst h264 pick is x264enc (no-element)"
printf 'h264=x264enc\nh264_reason=no-element\n' >"$LOG_DIR/encoder_caps"
amd_render GS_NVENC_PICK=x264enc
assert_eq 0 "$INLINE_RC" "render exits 0"
assert_contains "$INLINE_LOG" "${FINAL_X264}no-element)" "final encode line"
assert_empty "$(inline_calls trial)" "no trial"
check_no_va "x264enc pick"
assert_match "$(caps_re h264 h264 libx264 no-element)" "$(caps_lines)" "ENCODER-CAPS fields"

amd_case "AMD, the h264_vaapi trial fails, then a second render"
amd_render INLINE_FAIL_TRIAL=h264_vaapi
assert_eq 0 "$INLINE_RC" "render exits 0"
assert_eq "$TRIAL $VA_H264 -f null -"$'\n'"$TRIAL $VA_H264 -f null -" "$(inline_calls trial)" \
  "the trial runs once more after a failure"
assert_eq fail:1 "$(caps "$KEY_H264")" "trial cached as fail:1"
assert_contains "$INLINE_LOG" "${FINAL_X264}trial-fail)" "final encode line"
check_no_va "failed trial"
assert_contains "$(inline_calls 1)" " $X264 " "site 1 encodes with libx264"
assert_match "$(caps_re h264 h264 libx264 trial-fail)" "$(caps_lines)" "ENCODER-CAPS fields"
amd_render
assert_eq 0 "$INLINE_RC" "second render exits 0"
assert_empty "$(inline_calls trial)" "second render: the failed trial is not run again"
assert_contains "$INLINE_LOG" "${FINAL_X264}trial-fail)" "second render: final encode line"

amd_case "AMD, the h264_vaapi trial times out"
amd_render INLINE_FAIL_TRIAL=h264_vaapi INLINE_TRIAL_RC=124
assert_eq 0 "$INLINE_RC" "render exits 0"
assert_eq "$TRIAL $VA_H264 -f null -" "$(inline_calls trial)" "a timed-out trial is not run again"
assert_eq fail:124 "$(caps "$KEY_H264")" "trial cached as fail:124"
assert_contains "$INLINE_LOG" "${FINAL_X264}trial-timeout)" "final encode line"
check_no_va "timed-out trial"

# h265 requests that fall back to h264_vaapi, and a failing hevc_vaapi encode.
amd_case "AMD h265 request, the hevc_vaapi trial fails"
amd_render CLIP_VIDEO_CODEC=h265 INLINE_FAIL_TRIAL=hevc_vaapi
assert_eq 0 "$INLINE_RC" "render exits 0"
assert_eq "$TRIAL $VA_H264 -f null -"$'\n'"$TRIAL $VA_HEVC -f null -"$'\n'"$TRIAL $VA_HEVC -f null -" \
  "$(inline_calls trial)" "the h264_vaapi trial, then the hevc_vaapi trial twice"
assert_eq fail:1 "$(caps "$KEY_HEVC")" "hevc_vaapi trial cached as fail:1"
assert_contains "$INLINE_LOG" "h265 probe: gstreamer VA-API HEVC OK (pick=va:vah265enc)" "gst probe line"
assert_contains "$INLINE_LOG" "h265 probe: ffmpeg hevc_vaapi failed its one-frame trial at 1920x1080" \
  "ffmpeg probe line"
assert_contains "$INLINE_LOG" "h265 requested but unavailable (gst_ok=1 ffmpeg_ok=0)" "h265 choice"
check_va 1 "$VA_H264"
check_va 2 "$VA_H264"
assert_match "$(caps_re h265 h264 h264_vaapi trial-fail)" "$(caps_lines)" "ENCODER-CAPS fields"
assert_contains "$(caps_lines)" "WARN: ENCODER-CAPS" "ENCODER-CAPS logged with warn"

amd_case "AMD h265 request, the gst HEVC pick is none (no-element)"
printf 'h265=none\nh265_reason=no-element\n' >"$LOG_DIR/encoder_caps"
amd_render CLIP_VIDEO_CODEC=h265 GS_NVENC_PICK_H265=none
assert_eq 0 "$INLINE_RC" "render exits 0"
assert_contains "$INLINE_LOG" "h265 probe: gstreamer VA-API HEVC unavailable (reason=no-element)" "gst probe line"
assert_contains "$INLINE_LOG" "h265 requested but unavailable (gst_ok=0 ffmpeg_ok=0)" "h265 choice"
assert_eq "$TRIAL $VA_H264 -f null -" "$(inline_calls trial)" "no hevc_vaapi trial"
check_va 1 "$VA_H264"
assert_match "$(caps_re h265 h264 h264_vaapi no-element)" "$(caps_lines)" "ENCODER-CAPS fields"

amd_case "AMD h265 request, hevc_vaapi fails at site 3 (shape b)"
shape b
amd_render CLIP_VIDEO_CODEC=h265 INLINE_FAIL_SITE=3 "${SHAPE[@]}"
assert_ne 0 "$INLINE_RC" "render fails"
assert_eq "1 3" "$(inline_sites)" "site 3 runs once, no retry"
assert_not_contains "$INLINE_LOG" "WARN final encode" "no retry line"
assert_contains "$INLINE_LOG" "ERROR: ffmpeg concat (filter-graph) failed" "die_failed line"

# The h264_vaapi retry at the sites that end a render: the retry argv and the WARN line.
for spec in "b 3 1 3 3" "c 3 3 3" "d 4 1 copy 4 4"; do
  read -r s site want <<<"$spec"
  amd_case "AMD, h264_vaapi fails at site $site (shape $s)"
  shape "$s"
  amd_render INLINE_FAIL_SITE="$site" "${SHAPE[@]}"
  assert_eq 0 "$INLINE_RC" "render exits 0"
  assert_eq "$want" "$(inline_sites)" "sites"
  assert_contains "$INLINE_LOG" "[clip 0123abcd] $WARN_RETRY" "WARN line"
  check_va "$site" "$VA_H264"
  assert_eq "${X264_CALL[$site$s]}" "$(inline_calls "$site" | tail -n 1)" \
    "the retry runs the libx264 call of the site"
  assert_eq h264 "$(caps actual.inline)" "actual.inline"
  assert_eq retry-fail "$(caps reason.inline)" "reason.inline"
  assert_eq 2 "$(caps_lines | grep -c .)" "a second inline ENCODER-CAPS line"
  assert_match "WARN: $(caps_re h264 h264 libx264 retry-fail)" "$(caps_lines | tail -n 1)" \
    "second ENCODER-CAPS line"
done

# S4-U16 on AMD (shape a): the S4 C32 guards with the h264_vaapi retry.
amd_case "S4-U16 on AMD: h264_vaapi fails at site 2, then a render with no failure"
amd_render INLINE_FAIL_SITE=2
assert_eq 0 "$INLINE_RC" "render exits 0"
assert_match "$WARN_RETRY.*  concat: outro transcode retried with libx264, falling back to re-encode" \
  "$INLINE_LOG" "WARN line, then the retry note"
assert_empty "$(inline_cached)" "no outro and no staging file in OUTRO_CACHE_DIR"
assert_empty "$(inline_calls copy)" "no -c copy concat"
assert_eq "1 2 2 3" "$(inline_sites)" "sites"
check_va 2 "$VA_H264"
retry=$(inline_calls 2 | tail -n 1)
assert_eq "${X264_CALL[2a]% *}" "${retry% *}" \
  "the retry runs the libx264 call of site 2 (up to the staging file name)"
assert_contains "$(inline_calls 3)" "concat=n=2:v=1:a=1[v][a] -map [v] -map [a] $X264 " \
  "site 3 runs the concat-only graph with libx264"
assert_not_contains "$(inline_calls 3)" "-init_hw_device" "site 3 opens no VA device"
assert_eq retry-fail "$(caps reason.inline)" "reason.inline"
assert_match "WARN: $(caps_re h264 h264 libx264 retry-fail)" "$(caps_lines | tail -n 1)" \
  "second ENCODER-CAPS line"
amd_render
assert_eq 0 "$INLINE_RC" "second render exits 0"
assert_empty "$(inline_calls trial)" "second render: the passed trial is not run again"
assert_contains "$INLINE_LOG" "transcoding outro to match polished segments" "the outro is transcoded again"
assert_contains "$INLINE_LOG" "  concat: stream-copy OK" "stream-copy line"
assert_eq "1 2 copy" "$(inline_sites)" "second render sites"
check_va 2 "$VA_H264"
assert_match '^outro-[0-9a-f]{12}\.mp4$' "$(inline_cached)" "exactly one cached outro"

amd_case "S4-U16 on AMD: h264_vaapi fails at site 1"
amd_render INLINE_FAIL_SITE=1
assert_eq 0 "$INLINE_RC" "render exits 0"
assert_contains "$INLINE_LOG" "  polish[0]: [clip 0123abcd] $WARN_RETRY" "WARN line under the polish prefix"
assert_eq "${X264_CALL[1a]}" "$(inline_calls 1 | tail -n 1)" "the retry runs the libx264 call of site 1"
assert_empty "$(inline_calls 2)" "no site 2 transcode"
assert_empty "$(inline_calls copy)" "no -c copy concat"
assert_eq "1 1 3" "$(inline_sites)" "sites"
assert_contains "$INLINE_LOG" "STEP 9: ffmpeg concat 2 segments (with outro, filter-graph)" "STEP 9 line"
check_va 3 "$VA_H264"
assert_eq 1 "$(caps_lines | grep -c .)" "no second ENCODER-CAPS line from the polish subshell"
assert_eq ok "$(caps reason.inline)" "reason.inline"

amd_case "S4-U16 on AMD: h264_vaapi and its libx264 retry both fail at site 2"
amd_render INLINE_FAIL_SITE=2 INLINE_FAIL_COUNT=2
assert_eq 0 "$INLINE_RC" "render exits 0"
assert_contains "$INLINE_LOG" "  concat: outro transcode failed" "transcode failure line"
assert_not_contains "$INLINE_LOG" "retried with libx264" "no retry note"
assert_empty "$(inline_calls copy)" "no -c copy concat"
assert_empty "$(inline_cached)" "OUTRO_CACHE_DIR stays empty"
assert_eq "1 2 2 3" "$(inline_sites)" "sites"
assert_contains "$(inline_calls 3)" "-map [v] -map [a] $X264 " "site 3 encodes with libx264"
assert_not_contains "$(inline_calls 3)" "hwupload" "site 3 uploads nothing"

t_done
