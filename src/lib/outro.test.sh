#!/usr/bin/env bash
# Pure-bash harness for outro.sh. Stubs the _outro_* wrappers so no real
# curl/remotion/ffprobe runs. Run: bash src/lib/outro.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CLIP_OUT_DIR="$TMP/clips"
export OUTRO_DIR="$TMP/baked"
mkdir -p "$OUTRO_DIR"
fails=0
say() { :; }                       # silence lib logging
ok()  { if [ "$1" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3 (got '$1' want '$2')"; fails=$((fails+1)); fi; }

# shellcheck disable=SC1090
. "$HERE/outro.sh"

# Deterministic stubs (override the lib wrappers).
_outro_download() { : >"$2"; return 0; }                 # creates dest, succeeds
_outro_render()   { : >"$1"; return 0; }                 # creates dest, succeeds
_outro_upload()   { return 0; }
_outro_dims_ok()  { return 0; }

# 1) Inactive -> baked path
unset CLIP_OUTRO_URL CLIP_OUTRO_RENDER
: >"$OUTRO_DIR/outro_1920x1080_60.mp4"
ok "$(resolve_outro_file 1920x1080 60)" "$OUTRO_DIR/outro_1920x1080_60.mp4" "inactive returns baked"

# 2) Hit -> downloads to in-pod cache path
rm -rf "$CLIP_OUT_DIR"; export CLIP_OUTRO_URL="http://x/cache.mp4"; unset CLIP_OUTRO_RENDER
ok "$(resolve_outro_file 1920x1080 60)" "$CLIP_OUT_DIR/branded-outro/outro_1920x1080_60.mp4" "hit returns cache path"

# 3) Miss -> renders to in-pod cache path
rm -rf "$CLIP_OUT_DIR"; unset CLIP_OUTRO_URL; export CLIP_OUTRO_RENDER=1 CLIP_OUTRO_PUT_URL="http://x/put"
ok "$(resolve_outro_file 1280x720 60)" "$CLIP_OUT_DIR/branded-outro/outro_1280x720_60.mp4" "miss returns rendered path"

# 4) Render failure -> baked fallback
rm -rf "$CLIP_OUT_DIR"; _outro_render() { return 1; }; : >"$OUTRO_DIR/outro_1280x720_60.mp4"
ok "$(resolve_outro_file 1280x720 60)" "$OUTRO_DIR/outro_1280x720_60.mp4" "render failure falls back to baked"
_outro_render() { : >"$1"; return 0; }

# 5) will-append predicate
unset CLIP_OUTRO_URL CLIP_OUTRO_RENDER
if outro_will_append 1920x1080 60; then ok 0 0 "baked exists -> will append"; else ok 1 0 "baked exists -> will append"; fi
rm -f "$OUTRO_DIR/outro_1920x1080_60.mp4"
if outro_will_append 1920x1080 60; then ok 0 1 "no baked, no env -> will NOT append"; else ok 1 1 "no baked, no env -> will NOT append"; fi

# 6) outro_baked_exists predicate (drives the fuse gate)
: >"$OUTRO_DIR/outro_1920x1080_60.mp4"
if outro_baked_exists 1920x1080 60; then ok 0 0 "baked 60 exists -> baked_exists true"; else ok 1 0 "baked 60 exists -> baked_exists true"; fi
if outro_baked_exists 1920x1080 30; then ok 0 1 "no baked 30 -> baked_exists false"; else ok 1 1 "no baked 30 -> baked_exists false"; fi

[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
