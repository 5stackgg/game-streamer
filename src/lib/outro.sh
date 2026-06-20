# shellcheck shell=bash
# Branded-outro resolution for inline-clip-render.sh. Sourced, not executed.
# Resolves a single local outro mp4: branded S3 cache (hit), freshly rendered
# + uploaded (miss), or the baked stock outro (inactive / any failure).
# Env contract (set by the api): CLIP_OUTRO_URL | CLIP_OUTRO_RENDER(+CLIP_OUTRO_PUT_URL)
# + CLIP_BRAND_LOGO_URL / CLIP_BRAND_NAME / CLIP_BRAND_ACCENT.

_outro_baked_path() {
  printf '%s/outro_%s_%s.mp4' "${OUTRO_DIR:-/opt/game-streamer/resources/video}" "$1" "$2"
}
_outro_cache_path() {
  printf '%s/branded-outro/outro_%s_%s.mp4' "${CLIP_OUT_DIR:-/tmp/game-streamer/clips}" "$1" "$2"
}

# --- Mockable wrappers (tests override these) ---------------------------
_outro_download() { curl --fail --silent --show-error --max-time 60 -o "$2" "$1"; }
_outro_upload()   { curl --fail --silent --show-error --max-time 120 --upload-file "$1" "$2"; }
_outro_dims_ok() {
  local got; got=$(ffprobe -v error -select_streams v -show_entries stream=width,height \
    -of csv=s=x:p=0 "$1" 2>/dev/null)
  [ "$got" = "$2" ]
}
_outro_render() {
  local dest="$1" dims="$2" fps="$3" logo="$4" name="$5" accent="$6"
  local w="${dims%x*}" h="${dims#*x}"
  local props
  props=$(LOGO="$logo" NAME="$name" ACCENT="$accent" W="$w" H="$h" F="$fps" node -e \
    'process.stdout.write(JSON.stringify({width:+process.env.W,height:+process.env.H,fps:+process.env.F,durationS:3,logoUrl:process.env.LOGO||undefined,brandName:process.env.NAME||undefined,accent:process.env.ACCENT||undefined}))')
  local pin=()
  if command -v taskset >/dev/null 2>&1 && declare -F compute_cpu_split >/dev/null 2>&1; then
    compute_cpu_split; [ -n "${GS_CAPTURE_CPUS:-}" ] && pin=(taskset -c "$GS_CAPTURE_CPUS")
  fi
  ( cd "${MOTION_DIR:-/opt/game-streamer/motion}" && \
    "${pin[@]}" nice -n 19 node node_modules/.bin/remotion render src/index.ts Outro "$dest" \
      --codec=h264 --pixel-format=yuv420p --log=error --props="$props" )
}

# --- Public API ---------------------------------------------------------
# 0 if an outro will be appended (cheap; no download/render), else 1.
outro_will_append() {
  [ -n "${CLIP_OUTRO_URL:-}" ] && return 0
  [ "${CLIP_OUTRO_RENDER:-0}" = "1" ] && return 0
  [ -f "$(_outro_baked_path "$1" "$2")" ] && return 0
  return 1
}

# 0 if a baked stock outro for these dims/fps exists on disk, else 1. The fuse
# decision in inline-clip-render.sh gates on this: a baked fallback guarantees
# resolve_outro_file yields an existing file (so OUTRO_APPENDED stays 1) even if
# a branded download/render fails, so a deferred chip is always baked.
outro_baked_exists() {
  [ -f "$(_outro_baked_path "$1" "$2")" ]
}

# Prints the local outro mp4 path to append. Heavy — call once at concat time.
resolve_outro_file() {
  local dims="$1" fps="$2"
  local baked cached; baked="$(_outro_baked_path "$dims" "$fps")"; cached="$(_outro_cache_path "$dims" "$fps")"

  [ -f "$cached" ] && { printf '%s' "$cached"; return 0; }   # in-pod cache (prior clip)

  if [ -n "${CLIP_OUTRO_URL:-}" ]; then
    mkdir -p "$(dirname "$cached")"
    if _outro_download "$CLIP_OUTRO_URL" "$cached" && _outro_dims_ok "$cached" "$dims"; then
      printf '%s' "$cached"; return 0
    fi
    say "OUTRO: branded cache download failed/mismatch — using baked stock"
    rm -f "$cached"; printf '%s' "$baked"; return 0
  fi

  if [ "${CLIP_OUTRO_RENDER:-0}" = "1" ]; then
    mkdir -p "$(dirname "$cached")"
    if _outro_render "$cached" "$dims" "$fps" \
         "${CLIP_BRAND_LOGO_URL:-}" "${CLIP_BRAND_NAME:-}" "${CLIP_BRAND_ACCENT:-}" \
       && _outro_dims_ok "$cached" "$dims"; then
      if [ -n "${CLIP_OUTRO_PUT_URL:-}" ]; then
        _outro_upload "$cached" "$CLIP_OUTRO_PUT_URL" || say "OUTRO: cache upload failed (non-fatal)"
      fi
      printf '%s' "$cached"; return 0
    fi
    say "OUTRO: branded render failed — using baked stock"
    rm -f "$cached"; printf '%s' "$baked"; return 0
  fi

  printf '%s' "$baked"
}
