#!/usr/bin/env bash
# Pure-bash harness for outro.sh. Stubs the _outro_* wrappers so no real
# curl/remotion/ffprobe runs. Run: bash src/lib/outro.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CLIP_OUT_DIR="$TMP/clips"
export OUTRO_DIR="$TMP/baked"
CACHE="$CLIP_OUT_DIR/branded-outro"
mkdir -p "$OUTRO_DIR"
fails=0
say() { :; }                       # silence lib logging
ok()  { if [ "$1" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3 (got '$1' want '$2')"; fails=$((fails+1)); fi; }

# shellcheck disable=SC1090
. "$HERE/outro.sh"

# Deterministic stubs (override the lib wrappers).
CALLS="$TMP/calls"   # call markers: resolve_outro_file runs in a $(...) subshell
_outro_download() { : >>"$CALLS.download"; mkdir -p "$(dirname "$2")"; : >"$2"; return 0; }   # creates dest
_outro_render()   { : >>"$CALLS.render"; mkdir -p "$(dirname "$1")"; : >"$1"; return 0; }   # creates dest
_outro_upload()   { : >>"$CALLS.upload"; return 0; }
_outro_dims_ok()  { return 0; }

reset() { rm -rf "$CLIP_OUT_DIR"; unset CLIP_OUTRO_URL CLIP_OUTRO_RENDER CLIP_OUTRO_PUT_URL; }

# 1) Inactive -> baked path
reset; : >"$OUTRO_DIR/outro_1920x1080_60.mp4"
ok "$(resolve_outro_file 1920x1080 60)" "$OUTRO_DIR/outro_1920x1080_60.mp4" "inactive returns baked"

# 2) Hit -> cache file keyed on the presigned URL object basename (version-keyed)
reset; export CLIP_OUTRO_URL="https://s3/bucket/branding/outro_v1abc_1920x1080_60.mp4?X-Amz-Sig=z"
ok "$(resolve_outro_file 1920x1080 60)" "$CACHE/outro_v1abc_1920x1080_60.mp4" "hit returns version-keyed cache path"

# 3) Miss -> render to version-keyed path (from the PUT url basename)
reset; export CLIP_OUTRO_RENDER=1 CLIP_OUTRO_PUT_URL="https://s3/bucket/branding/outro_v2def_1280x720_60.mp4?sig=z"
ok "$(resolve_outro_file 1280x720 60)" "$CACHE/outro_v2def_1280x720_60.mp4" "miss returns version-keyed render path"

# 4) Render failure -> baked fallback
reset; : >"$OUTRO_DIR/outro_1280x720_60.mp4"; export CLIP_OUTRO_RENDER=1 CLIP_OUTRO_PUT_URL="https://s3/branding/outro_v9_1280x720_60.mp4?s=1"
_outro_render() { return 1; }
ok "$(resolve_outro_file 1280x720 60)" "$OUTRO_DIR/outro_1280x720_60.mp4" "render failure falls back to baked"
_outro_render() { : >>"$CALLS.render"; mkdir -p "$(dirname "$1")"; : >"$1"; return 0; }

# 5) Download dims-mismatch -> baked fallback
reset; : >"$OUTRO_DIR/outro_1920x1080_60.mp4"; export CLIP_OUTRO_URL="https://s3/branding/outro_v5_1920x1080_60.mp4?s=1"
_outro_dims_ok() { return 1; }
ok "$(resolve_outro_file 1920x1080 60)" "$OUTRO_DIR/outro_1920x1080_60.mp4" "download dims-mismatch falls back to baked"
_outro_dims_ok() { return 0; }

# 6) Version-keying: a stale old-version cache file is NOT reused for a new version
reset; mkdir -p "$CACHE"; : >"$CACHE/outro_OLDVER_1920x1080_60.mp4"
export CLIP_OUTRO_URL="https://s3/branding/outro_NEWVER_1920x1080_60.mp4?s=1"
ok "$(resolve_outro_file 1920x1080 60)" "$CACHE/outro_NEWVER_1920x1080_60.mp4" "new branding version not masked by stale cache"

# 7) Unparseable URL object name -> falls back to dims/fps cache key
reset; export CLIP_OUTRO_URL="https://s3/weird"
ok "$(resolve_outro_file 1920x1080 60)" "$CACHE/outro_1920x1080_60.mp4" "unparseable url -> dims/fps cache key"

# 7b) Basename with metacharacters -> sanitized to the safe dims/fps name
reset; export CLIP_OUTRO_URL="https://s3/branding/outro_'evil_1920x1080_60.mp4?s=1"
ok "$(resolve_outro_file 1920x1080 60)" "$CACHE/outro_1920x1080_60.mp4" "metachar basename -> safe dims/fps name"

# 8) outro_will_append predicate (baked / none / URL / RENDER)
reset; : >"$OUTRO_DIR/outro_1920x1080_60.mp4"
if outro_will_append 1920x1080 60; then ok 0 0 "baked exists -> will append"; else ok 1 0 "baked exists -> will append"; fi
rm -f "$OUTRO_DIR/outro_1920x1080_60.mp4"
if outro_will_append 1920x1080 60; then ok 0 1 "no baked, no env -> NOT append"; else ok 1 1 "no baked, no env -> NOT append"; fi
export CLIP_OUTRO_URL="https://s3/branding/outro_x_1920x1080_60.mp4?s=1"
if outro_will_append 1920x1080 60; then ok 0 0 "CLIP_OUTRO_URL set -> will append"; else ok 1 0 "CLIP_OUTRO_URL set -> will append"; fi
unset CLIP_OUTRO_URL; export CLIP_OUTRO_RENDER=1
if outro_will_append 1920x1080 60; then ok 0 0 "CLIP_OUTRO_RENDER=1 -> will append"; else ok 1 0 "CLIP_OUTRO_RENDER=1 -> will append"; fi

# 9) outro_baked_exists predicate (drives the fuse gate)
reset; : >"$OUTRO_DIR/outro_1920x1080_60.mp4"
if outro_baked_exists 1920x1080 60; then ok 0 0 "baked 60 exists -> true"; else ok 1 0 "baked 60 exists -> true"; fi
if outro_baked_exists 1920x1080 30; then ok 0 1 "no baked 30 -> false"; else ok 1 1 "no baked 30 -> false"; fi

# 10-14) Branded key vs the clip's own dims/fps. The guard is a backstop for a
# key made for other dims/fps (for example by an older api that keyed the pod
# outro on the global clip settings).
# calls lists the stubs run since the last clear_calls.
calls() { local n="" k; for k in download render upload; do [ -e "$CALLS.$k" ] && n="$n $k"; done; printf '%s' "${n# }"; }
clear_calls() { rm -f "$CALLS".*; }

# 10) Hit keyed for other dims -> baked for the clip's dims, nothing downloaded
reset; clear_calls; : >"$OUTRO_DIR/outro_1280x720_60.mp4"
export CLIP_OUTRO_URL="https://s3/branding/outro_v10_1920x1080_60.mp4?s=1"
ok "$(resolve_outro_file 1280x720 60)" "$OUTRO_DIR/outro_1280x720_60.mp4" "hit keyed for other dims -> baked for the clip's dims"
ok "$(calls)" "" "hit keyed for other dims -> no download"

# 11) Hit keyed for other fps only -> baked for the clip's fps, nothing downloaded
reset; clear_calls
export CLIP_OUTRO_URL="https://s3/branding/outro_v11_1920x1080_60.mp4?s=1"
ok "$(resolve_outro_file 1920x1080 30)" "$OUTRO_DIR/outro_1920x1080_30.mp4" "hit keyed for other fps -> baked for the clip's fps"
ok "$(calls)" "" "hit keyed for other fps -> no download"

# 12) Miss keyed for other dims -> baked, no render and no upload under that key
reset; clear_calls; : >"$OUTRO_DIR/outro_1280x720_60.mp4"
export CLIP_OUTRO_RENDER=1 CLIP_OUTRO_PUT_URL="https://s3/branding/outro_v12_1920x1080_60.mp4?s=1"
ok "$(resolve_outro_file 1280x720 60)" "$OUTRO_DIR/outro_1280x720_60.mp4" "miss keyed for other dims -> baked"
ok "$(calls)" "" "miss keyed for other dims -> no render, no upload"

# 13) In-pod file from a matching clip is not reused by a clip of other dims
reset; clear_calls; : >"$OUTRO_DIR/outro_1280x720_60.mp4"
export CLIP_OUTRO_URL="https://s3/branding/outro_v13_1920x1080_60.mp4?s=1"
ok "$(resolve_outro_file 1920x1080 60)" "$CACHE/outro_v13_1920x1080_60.mp4" "matching clip fills the in-pod cache"
ok "$(calls)" "download" "matching clip downloads"
clear_calls
ok "$(resolve_outro_file 1280x720 60)" "$OUTRO_DIR/outro_1280x720_60.mp4" "other-dims clip skips the in-pod file"
ok "$(calls)" "" "other-dims clip -> no download"

# 14) Miss keyed for the clip's dims and fps (30) -> render + upload as before
reset; clear_calls
export CLIP_OUTRO_RENDER=1 CLIP_OUTRO_PUT_URL="https://s3/branding/outro_v14_1280x720_30.mp4?s=1"
ok "$(resolve_outro_file 1280x720 30)" "$CACHE/outro_v14_1280x720_30.mp4" "miss keyed for the clip's dims/fps -> render path"
ok "$(calls)" "render upload" "miss keyed for the clip's dims/fps -> render + upload"

[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
