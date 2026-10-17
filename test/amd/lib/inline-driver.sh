# shellcheck shell=bash
# shellcheck disable=SC2016  # the stub bodies and the t_run script expand when they run
# shellcheck disable=SC2034  # INLINE_RC and INLINE_LOG are read by the test files
# End-to-end driver for src/lib/inline-clip-render.sh, used by test/amd/encode-inline.sh
# (the NVIDIA goldens and the stream-copy retry guard) and test/amd/encode-inline-amd.sh
# (the VA-API paths). Source it after lib/harness.sh and lib/golden.sh:
#
#   inline_case "h264, one segment, chip and outro"
#   inline_render CLIP_VIDEO_CODEC=h264
#   assert_eq 0 "$INLINE_RC" "render exits 0"
#   t_golden h264-one-segment "$(inline_golden_text)"
#
# inline_case starts a harness case, empties the fixed directories below, puts the outro
# fixture in place and writes these stubs into $T_BIN, which is first on PATH:
#   ffmpeg           records its argv. '-encoders' lists hevc_nvenc unless
#                    INLINE_FFMPEG_NO_HEVC=1. A test encode (last argument '-') passes,
#                    except h264_nvenc with INLINE_NVENC_TRIAL=none, h264_nvenc with
#                    -b_ref_mode with INLINE_NVENC_TRIAL=nobref, and an encoder named in
#                    INLINE_FAIL_TRIAL (a space-separated list), which exits with
#                    INLINE_TRIAL_RC (default 1). Any other call writes 2 KiB to its last
#                    argument and exits 0, unless it is a -c copy concat and
#                    INLINE_COPY_FAIL=1, or its site (see _inline_site) is
#                    INLINE_FAIL_SITE and that site has run no more than INLINE_FAIL_COUNT
#                    (default 1) times in this render: then it exits 1.
#   ffprobe          'audio' for a stream probe, 1.000000 for a duration probe.
#   node             the clip-helpers subcommands the render calls, `node -e`, and the
#                    remotion chip render, which writes 2 KiB to the chip .mov.
#   curl             the status api and the spec-server endpoints, all answering 200.
#   gst-launch-1.0   writes 2 KiB to its filesink location, then waits for SIGINT.
#   gst-inspect-1.0  exits 1.
# A render in ubuntu:24.04 with these stubs prints no 'command not found' line, so no other
# command needs a stub.
# Optional encoder-mode fixtures, inactive by default:
#   INLINE_CPU_AT_SEEK_TICK=N: write the pod CPU marker on a seek at or above N.
#   INLINE_RECORD_CAPTURE=1: append selected GST elements to inline/capture.encoders.
#   INLINE_NO_AUDIO_SEG=N: the zero-based segment has no audio stream.
#   INLINE_PAD_FAIL=1: silent-pad calls fail; a graph using that missing audio fails.
#   INLINE_CAPTURE_DEATH_MODE=gpu|all and INLINE_CAPTURE_DEATH_SEG=N: kill a live
#     selected capture during a monitor GET, once per PID; all also kills its CPU redo.
#   INLINE_CAPTURE_START_FAIL=gpu|cpu|all: selected capture attempts die on spawn.
#   INLINE_CAPTURE_BYTES=N: capture size (default2048), including an unusable zero.
#   capture.events records starts, deaths and pause/marker order for these fixtures.
# inline_render [VAR=VALUE ...] runs one render, bounded by timeout, and sets INLINE_RC
# and INLINE_LOG. The render's stdout and stderr, in order, are in
# $T_TMP/inline/render.log; the ffmpeg calls, one line each with every argument quoted by
# printf %q, are in $T_TMP/inline/ffmpeg.argv. Both are emptied at the start of a render;
# the probe cache, LOG_DIR and the outro cache are kept until the next inline_case.

# The outro, the clip output and the outro cache sit at fixed paths: the outro cache key
# hashes the outro path, size and mtime, and these paths show in the goldens.
INLINE_FIXED=/tmp/gs-inline-test
INLINE_OUTRO_DIR="$INLINE_FIXED/outro"
INLINE_OUT_DIR="$INLINE_FIXED/clips"
INLINE_CACHE_DIR="$INLINE_FIXED/outro-cache"
INLINE_RC=""
INLINE_LOG=""
trap 'rm -rf "$T_ROOT" "$INLINE_FIXED"' EXIT

# _inline_site ARG...
# Names the render call an ffmpeg argv belongs to: encoders (the h265 probe), trial (a test
# encode, last argument '-'), 3 (concat=n=, the filter-graph concat, concat-only or
# fused), 1 (the chip overlay polish of segment 0), copy (a -c copy concat), 4 (the -f
# concat re-encode), 2 (the outro transcode) or other (the thumbnail, a silence pad).
_inline_site() {
  local a=" $* "
  case "$a" in
    *" -encoders "*) echo encoders; return 0 ;;
  esac
  if [ "${*: -1}" = "-" ]; then
    echo trial
    return 0
  fi
  case "$a" in
    *concat=n=*) echo 3 ;;
    *"[0:v][1:v]overlay"*) echo 1 ;;
    *" -c copy "*) echo copy ;;
    *" -f concat "*) echo 4 ;;
    *" -filter_complex "*) echo other ;;
    *"/outro_"*) echo 2 ;;
    *) echo other ;;
  esac
}

_inline_stub() {
  local name="$1" body="$2"
  {
    printf '#!/usr/bin/env bash\n'
    printf '# %s stub written by test/amd/lib/inline-driver.sh\n' "$name"
    [ "$name" = ffmpeg ] && declare -f _inline_site
    printf '%s\n' "$body"
  } >"$T_BIN/$name"
  chmod +x "$T_BIN/$name"
}

_inline_stubs() {
  _inline_stub ffmpeg '
d="$T_TMP/inline"
rec="" q=""
for a in "$@"; do printf -v q "%q" "$a"; rec+="${rec:+ }$q"; done
printf "%s\n" "$rec" >>"$d/ffmpeg.argv"
site=$(_inline_site "$@")
case "$site" in
  encoders)
    if [ "${INLINE_FFMPEG_NO_HEVC:-0}" != 1 ]; then
      echo " V....D hevc_nvenc           NVIDIA NVENC hevc encoder (codec hevc)"
    fi
    exit 0 ;;
  trial)
    enc="" prev=""
    for a in "$@"; do [ "$prev" = -c:v ] && enc="$a"; prev="$a"; done
    case "${INLINE_NVENC_TRIAL:-ok}:$enc" in
      none:h264_nvenc) exit 1 ;;
      nobref:h264_nvenc) case " $* " in *" -b_ref_mode "*) exit 1 ;; esac ;;
    esac
    case " ${INLINE_FAIL_TRIAL:-} " in
      *" $enc "*) exit "${INLINE_TRIAL_RC:-1}" ;;
    esac
    exit 0 ;;
  copy)
    [ "${INLINE_COPY_FAIL:-0}" = 1 ] && exit 1 ;;
  "${INLINE_FAIL_SITE:-none}")
    n=$(( $(cat "$d/site$site.count" 2>/dev/null || echo 0) + 1 ))
    echo "$n" >"$d/site$site.count"
    [ "$n" -le "${INLINE_FAIL_COUNT:-1}" ] && exit 1 ;;
esac
if [ "${INLINE_PAD_FAIL:-0}" = 1 ]; then
  case "${*: -1}" in *.aud.mp4) exit 1 ;; esac
  if [ "$site" = 3 ] && [ -n "${INLINE_NO_AUDIO_SEG:-}" ]; then
    printf -v no_audio "seg-%03d.mp4" "$INLINE_NO_AUDIO_SEG"
    case " $* " in *"$no_audio"*) exit 1 ;; esac
  fi
fi
head -c 2048 /dev/zero >"${*: -1}"
exit 0'
  _inline_stub ffprobe '
case " $* " in
  *" stream=codec_type "*)
    if [ -n "${INLINE_NO_AUDIO_SEG:-}" ]; then
      printf -v no_audio "seg-%03d.mp4" "$INLINE_NO_AUDIO_SEG"
      case " $* " in *"$no_audio"*) exit 0 ;; esac
    fi
    echo audio ;;
  *) echo 1.000000 ;;
esac
exit 0'
  _inline_stub node '
segs() { tr "{" "\n" | sed -n "s/.*\"start_tick\":\([0-9]*\).*\"end_tick\":\([0-9]*\).*/\1 \2/p"; }
case "${1:-}" in
  -e) printf "{}"; exit 0 ;;
  node_modules/.bin/remotion) head -c 2048 /dev/zero >"$5"; exit 0 ;;
esac
case "${2:-}" in
  segs-count) segs | awk "END { printf \"%d\", NR }" ;;
  segs-total-ticks) segs | awk "{ t += \$2 - \$1 } END { printf \"%d\", t }" ;;
  segs-table) segs | awk "{ print \$1 \"|\" \$2 \"||\" }" ;;
  state-tick) cat >/dev/null; printf 100 ;;
  state-paused) cat >/dev/null; printf true ;;
  state-seeking) cat >/dev/null; printf 0 ;;
  status-field) cat >/dev/null; printf rendering ;;
  status-body) printf "{}" ;;
  *) [ -t 0 ] || cat >/dev/null ;;
esac
exit 0'
  _inline_stub curl '
d="$T_TMP/inline"
url="" wo=0 body=0 prev=""
for a in "$@"; do
  case "$a" in http://*|https://*) url="$a" ;; esac
  [ "$prev" = --write-out ] && wo=1
  [ "$prev" = --data-binary ] && [ "$a" = @- ] && body=1
  prev="$a"
done
payload=""
if [ "$body" = 1 ]; then payload=$(cat); fi
if [ "${INLINE_CPU_AT_SEEK_TICK:-0}" -gt 0 ] 2>/dev/null; then
  case "$url" in
    */demo/seek)
      re="\"tick\"[[:space:]]*:[[:space:]]*([0-9]+)"
      if [[ "$payload" =~ $re ]] && [ "${BASH_REMATCH[1]}" -ge "$INLINE_CPU_AT_SEEK_TICK" ]; then
        : > "$LOG_DIR/cpu-fallback"
      fi
      ;;
  esac
fi
if [ -n "${INLINE_CAPTURE_DEATH_MODE:-}" ]; then
  case "$url" in
    */demo/pause)
      marker=0; [ -e "$LOG_DIR/cpu-fallback" ] && marker=1
      printf "pause marker=%s\n" "$marker" >> "$d/capture.events"
      ;;
  esac
fi
if [ "$wo" = 1 ]; then printf 200; exit 0; fi
case "$url" in
  */demo/state) printf "{\"tick\":100,\"paused\":true}" ;;
  */demo/seek-state) printf "0|" ;;
  */demo/capture-fields*)
    if [ -n "${INLINE_CAPTURE_DEATH_MODE:-}" ]; then
      pid=$(cat "$d/capture.pid" 2>/dev/null || true)
      captured=$(cat "$d/capture.file" 2>/dev/null || true)
      enc=$(cat "$d/capture.encoder" 2>/dev/null || true)
      printf -v wanted "seg-%03d.mp4" "${INLINE_CAPTURE_DEATH_SEG:-0}"
      case "$captured" in
        */"$wanted")
          if [ "${pid:-0}" -gt 1 ] 2>/dev/null && kill -0 "$pid" 2>/dev/null \
             && [ ! -e "$d/killed.$pid" ]; then
            if [ "$INLINE_CAPTURE_DEATH_MODE" = all ] || [ "$enc" != x264enc ]; then
              : > "$d/killed.$pid"
              printf "die %s %s\n" "$enc" "${captured##*/}" >> "$d/capture.events"
              kill -TERM "$pid" 2>/dev/null || true
            fi
          fi
          ;;
      esac
    fi
    n=$(( $(cat "$d/cf.count" 2>/dev/null || echo 0) + 1 ))
    echo "$n" >"$d/cf.count"
    printf "live|%d|%d|100|live|5|0" $((100000 - n)) "$n" ;;
  */demo/pov-state*) printf "|1|10|100" ;;
  */demo/demoui-score) printf "0|0|0" ;;
esac
exit 0'
  # Background jobs of a non-interactive bash start with SIGINT ignored, and an ignored
  # signal stays ignored across exec, so the stub resets it for stop_clip_capture.
  _inline_stub gst-launch-1.0 '
out=""
for a in "$@"; do
  case "$a" in location=*) out="${a#location=}" ;; esac
done
[ -n "$out" ] || exit 0
if [ "${INLINE_RECORD_CAPTURE:-0}" = 1 ] || [ -n "${INLINE_CAPTURE_DEATH_MODE:-}" ] \
   || [ -n "${INLINE_CAPTURE_START_FAIL:-}" ]; then
  enc=""
  for a in "$@"; do
    case "$a" in nvcudah*enc|nvh*enc|va*enc|x264enc) enc="$a" ;; esac
  done
  if [ "${INLINE_RECORD_CAPTURE:-0}" = 1 ]; then
    printf "%s\n" "$enc" >> "$T_TMP/inline/capture.encoders"
  fi
  marker=0; [ -e "$LOG_DIR/cpu-fallback" ] && marker=1
  printf "start %s %s marker=%s\n" "$enc" "${out##*/}" "$marker" >> "$T_TMP/inline/capture.events"
  if [ -n "${INLINE_CAPTURE_DEATH_MODE:-}" ]; then
    printf "%s\n" "$$" > "$T_TMP/inline/capture.pid"
    printf "%s\n" "$out" > "$T_TMP/inline/capture.file"
    printf "%s\n" "$enc" > "$T_TMP/inline/capture.encoder"
  fi
  case "${INLINE_CAPTURE_START_FAIL:-}:$enc" in
    all:*|gpu:nvcudah*|gpu:nvh*|gpu:va*|cpu:x264enc) exit 1 ;;
  esac
fi
head -c "${INLINE_CAPTURE_BYTES:-2048}" /dev/zero >"$out"
exec env --default-signal=INT sleep 3600'
  _inline_stub gst-inspect-1.0 'exit 1'
  # The simulated CS2 process is alive; other process searches find nothing.
  _inline_stub pgrep '[ "${1:-}" = -f ] && [ "${2:-}" = /linuxsteamrt64/cs2 ]'
}

# inline_case NAME
# Starts a case for a render: t_case, empty fixed directories, the outro fixture
# (outro_1920x1080_60.mp4, 2 KiB, mtime 0), a chip motion dir, the demoui marker and the
# stubs.
inline_case() {
  t_case "$1"
  rm -rf "$INLINE_FIXED"
  mkdir -p "$INLINE_OUTRO_DIR" "$INLINE_OUT_DIR" "$INLINE_CACHE_DIR" "$T_TMP/inline/motion"
  head -c 2048 /dev/zero >"$INLINE_OUTRO_DIR/outro_1920x1080_60.mp4"
  touch -d @0 "$INLINE_OUTRO_DIR/outro_1920x1080_60.mp4"
  : >"$T_TMP/inline/demoui-verified"
  _inline_stubs
}

# inline_segments N
# Prints a CLIP_SEGMENTS value with N segments of 64 ticks (one second) each.
inline_segments() {
  local i out=""
  for ((i = 1; i <= $1; i++)); do
    out+="${out:+,}{\"start_tick\":$((i * 1000)),\"end_tick\":$((i * 1000 + 64))}"
  done
  printf '[%s]' "$out"
}

# inline_render [VAR=VALUE ...]
# Runs src/lib/inline-clip-render.sh once. The defaults give one segment, a chip (the
# display name and an existing MOTION_DIR), the outro, no fused pass
# (CLIP_MAX_FUSED_SEGMENTS=0), h264, 1920x1080 at 60 fps, ximagesrc capture and the
# NVIDIA gst picks; VAR=VALUE pairs override them.
inline_render() {
  rm -f "$T_TMP/inline/render.log" "$T_TMP/inline/ffmpeg.argv" "$T_TMP/inline/"*.count
  t_run \
    CLIP_RENDER_JOB_ID=0123abcd-0000-4000-8000-000000000001 \
    CLIP_RENDER_TOKEN=test-token \
    STATUS_API_BASE=http://status.invalid \
    SPEC_SERVER_URL=http://spec.invalid \
    CLIP_SEGMENTS="$(inline_segments 1)" \
    CLIP_CAPTURE_METHOD=ximagesrc DISPLAY=:99 CLIP_CAPTURE_DIAG=0 CLIP_WARMUP=0 \
    CLIP_DEMOUI_MARKER="$T_TMP/inline/demoui-verified" \
    GS_PROBE_CACHE="$T_TMP/inline/probes.env" \
    GS_NVENC_PICK=nvcudah264enc GS_NVENC_PICK_H265=nvcudah265enc \
    CLIP_OUTPUT_DIMS=1920x1080 CLIP_OUTPUT_FPS=60 \
    CLIP_OUT_DIR="$INLINE_OUT_DIR" OUTRO_DIR="$INLINE_OUTRO_DIR" \
    OUTRO_CACHE_DIR="$INLINE_CACHE_DIR" \
    MOTION_DIR="$T_TMP/inline/motion" CLIP_DISPLAY_NAME=Player \
    CLIP_MAX_FUSED_SEGMENTS=0 CLIP_VIDEO_CODEC=h264 \
    "$@" -- \
    'timeout -k 5 120 bash "$GS_REPO/src/lib/inline-clip-render.sh" >"$T_TMP/inline/render.log" 2>&1'
  INLINE_RC=$T_RC
  INLINE_LOG=$(cat "$T_TMP/inline/render.log" 2>/dev/null)
}

# inline_calls SITE
# Prints the last render's ffmpeg calls of SITE (as _inline_site names it), in call
# order, one per line with the arguments joined by spaces and unquoted.
inline_calls() {
  local want="$1" line
  local -a args
  [ -f "$T_TMP/inline/ffmpeg.argv" ] || return 0
  while IFS= read -r line; do
    eval "args=($line)"
    if [ "$(_inline_site "${args[@]}")" = "$want" ]; then
      printf '%s\n' "${args[*]}"
    fi
  done <"$T_TMP/inline/ffmpeg.argv"
  return 0
}

# inline_sites
# Prints the sites of the last render's encode calls and -c copy concats in call order,
# separated by spaces, leaving out the trials, the h265 probe and the other calls: for
# example '1 2 copy'.
inline_sites() {
  local line site out=""
  local -a args
  [ -f "$T_TMP/inline/ffmpeg.argv" ] || return 0
  while IFS= read -r line; do
    eval "args=($line)"
    site=$(_inline_site "${args[@]}")
    case "$site" in
      1 | 2 | 3 | 4 | copy) out+="${out:+ }$site" ;;
    esac
  done <"$T_TMP/inline/ffmpeg.argv"
  printf '%s' "$out"
}

# inline_cached
# Prints the file names in the outro cache, sorted, one per line.
inline_cached() {
  find "$INLINE_CACHE_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort
}

# inline_golden_text [cut|u16]
# Prints the golden text of the last render: '== ffmpeg' and every ffmpeg call as
# recorded, then '== log' and the render's 'final encode', h265 probe and choice,
# 'OUTRO:', 'STEP 9' and '  concat:' lines. The U+2014 dash of upstream log lines
# becomes @EMDASH@ and the PID of a '.mp4.<pid>.tmp' staging path becomes @PID@. With
# cut, the calls stop at the libx264 retry of the site 2 outro transcode and the log at
# the retry's WARN line: in a render that would take the outro stream-copy fast path,
# what follows a retry changes with the S4 C32 guard (S4-U16 checks that part). With
# u16, only the S4-U16 golden parts are kept: the calls at sites 1, 2 and 3 and the -c
# copy concat, and the 'OUTRO:', 'STEP 9', '  concat:' and 'WARN final encode' lines.
inline_golden_text() {
  local dash argv log line
  local -a args
  dash=$(printf '\342\200\224')
  argv=$(cat "$T_TMP/inline/ffmpeg.argv" 2>/dev/null)
  log=$(grep -E 'final encode|h265 (probe|selected|requested)|OUTRO:|STEP 9|  concat:' \
    "$T_TMP/inline/render.log" 2>/dev/null)
  case "${1:-}" in
    cut)
      argv=$(printf '%s\n' "$argv" | awk '{ print } /libx264/ && /outro-cache/ { exit }')
      log=$(printf '%s\n' "$log" | awk '{ print } /WARN final encode/ { exit }')
      ;;
    u16)
      argv=$(while IFS= read -r line; do
        eval "args=($line)"
        case "$(_inline_site "${args[@]}")" in
          1 | 2 | 3 | copy) printf '%s\n' "$line" ;;
        esac
      done <<<"$argv")
      log=$(printf '%s\n' "$log" | grep -E 'OUTRO:|STEP 9|  concat:|WARN final encode')
      ;;
  esac
  printf '== ffmpeg\n%s\n== log\n%s\n' "$argv" "$log" \
    | sed -e "s/$dash/@EMDASH@/g" -e 's/\.mp4\.[0-9][0-9]*\.tmp/.mp4.@PID@.tmp/g'
}
