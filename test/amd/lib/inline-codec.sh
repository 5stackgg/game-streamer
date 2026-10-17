# shellcheck shell=bash
# shellcheck disable=SC2016  # the stub body expands when the stub runs
# Runs the codec-choice block of src/lib/inline-clip-render.sh alone. Before that block
# the script requires the job env and probes the spec server with curl, and after it the
# script drives CS2 through the demo, so ic_run cuts the block out, from the line
# CLIP_VIDEO_CODEC="${CLIP_VIDEO_CODEC:-h264}" through the line export CLIP_VIDEO_CODEC,
# and sources it in a clean shell the way the script reaches it: set -uo pipefail,
# SCRIPT_TAG=inline-clip, common.sh, then the script's LOG_PREFIX and say. Sourced after
# test/amd/lib/encode-sites.sh, whose es_case stubs it reuses.

# ic_case NAME: es_case NAME, plus the ffmpeg stub of ic_stub_ffmpeg.
ic_case() {
  es_case "$1"
  ic_stub_ffmpeg
}

# ic_stub_ffmpeg: the ffmpeg stub of ic_case, also for a case started another way (for
# example with es_amd_case). Its switches, passed to ic_run as VAR=VALUE pairs:
#   T_FF_FULL_RC    exit status of the h264_nvenc test encode with -b_ref_mode (default 0)
#   T_FF_NOBREF_RC  exit status of the test encode without it (default 0)
#   T_FF_HEVC=0     'ffmpeg -encoders' lists no hevc_nvenc
ic_stub_ffmpeg() {
  t_stub ffmpeg 'case " $* " in
  *" -encoders "*)
    printf "%s\n" " V....D libx264              libx264 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10 (codec h264)" \
      " V....D h264_nvenc           NVIDIA NVENC H.264 encoder (codec h264)"
    [ "${T_FF_HEVC:-1}" = 1 ] && printf "%s\n" " V....D hevc_nvenc           NVIDIA NVENC hevc encoder (codec hevc)"
    exit 0
    ;;
  *" -b_ref_mode "*) exit "${T_FF_FULL_RC:-0}" ;;
  *" -frames:v 8 "*) exit "${T_FF_NOBREF_RC:-0}" ;;
esac
exit 0'
}

# _ic_script: the script ic_run runs. It exits 3 when the two anchor lines do not bound
# exactly one block.
_ic_script() {
  cat <<'IC_EOF'
set -uo pipefail
SCRIPT_TAG=inline-clip
. "$GS_REPO/src/lib/common.sh"
LOG_PREFIX="[clip ${CLIP_RENDER_JOB_ID:0:8}]"
say() { printf '%s %s\n' "$LOG_PREFIX" "$*" >&2; }
awk -v s='CLIP_VIDEO_CODEC="${CLIP_VIDEO_CODEC:-h264}"' -v e='export CLIP_VIDEO_CODEC' '
  { t = $0; sub(/^[ \t]+/, "", t) }
  t == s { n++; if (n == 1) on = 1 }
  on { print }
  on && t == e { on = 0; done = 1 }
  END { exit !(n == 1 && done) }
' "$GS_REPO/src/lib/inline-clip-render.sh" >"$T_TMP/codec-choice.sh" || {
  echo "ic_run: no single codec-choice block in src/lib/inline-clip-render.sh" >&2
  exit 3
}
. "$T_TMP/codec-choice.sh"
echo "codec=$CLIP_VIDEO_CODEC"
echo "venc=${FFMPEG_VENC_ARGS[*]}"
echo "h264=${H264_VENC_ARGS[*]}"
echo "final_encoder=${CLIP_FINAL_ENCODER-(unset)}"
echo "h265_ok=gst:${GST_H265_OK-(unset)} ffmpeg:${FFMPEG_H265_OK-(unset)}"
IC_EOF
}

# ic_run [VAR=VALUE ...]: runs the block with CLIP_RENDER_JOB_ID=a1b2c3d4e5f60718 and the
# probe cache in the case's temp dir (empty after ic_case), then prints what it leaves for
# the encode sites: codec= (the exported CLIP_VIDEO_CODEC), venc= (FFMPEG_VENC_ARGS), h264=
# (H264_VENC_ARGS), final_encoder= (CLIP_FINAL_ENCODER) and h265_ok= (the two HEVC
# verdicts; "(unset)" outside the h265 arm).
ic_run() {
  t_run CLIP_RENDER_JOB_ID=a1b2c3d4e5f60718 GS_PROBE_CACHE="$T_TMP/gst-probes.env" "$@" \
    -- "$(_ic_script)"
}

# ic_text: stderr (the say lines and common.sh's log lines), stdout (the choice) and the
# ffmpeg calls of the last ic_run as one text, with the upstream U+2014 as @EMDASH@. The
# block's say lines carry no indentation of their own, so moving them deeper in the
# source leaves this text as it is.
ic_text() {
  local text
  text="--- stderr"$'\n'"$T_STDERR"$'\n'"--- stdout"$'\n'"$T_STDOUT"$'\n'"--- ffmpeg"$'\n'"$(t_calls ffmpeg)"
  printf '%s' "${text//"$ES_DASH"/@EMDASH@}"
}
