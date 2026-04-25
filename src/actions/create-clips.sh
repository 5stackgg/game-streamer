#!/usr/bin/env bash
# MODE=create-clips — DRAFT, not production-verified.
# Replays a CS2 demo via Steam IPC and records a per-clip mp4. The
# upstream pipeline that feeds DEMO_PATH/START_TICK/etc and the
# downstream upload (will be a TypeScript service) are not built yet.
#
# Assumes ../game-streamer.sh::prepare_runtime has already run (Steam
# logged in, CS2 installed/up-to-date, Xorg + audio up).
#
# Required env:
#   DEMO_PATH      absolute path to the .dem file
#   CLIP_NAME      output filename (no extension)
#   START_TICK     tick to seek to (lead-in is added)
#   END_TICK       tick the clip ends at
#   SPEC_SLOT      CS2 spec_player slot (1..n)
#
# Optional env:
#   CLIPS_DIR              default /mnt/game-streamer/clips
#   CLIP_LEAD_SECONDS      seconds before START_TICK to start recording (default 5)
#   CLIP_TAIL_SECONDS      seconds after  END_TICK   to stop recording  (default 3)
#
# Upload of the produced mp4 is intentionally not wired here — a
# separate TypeScript service will consume $CLIPS_DIR.
set -euo pipefail

LOG_TAG=create-clips
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=lib/cs2.sh
. "$SCRIPT_DIR/../lib/cs2.sh"
# shellcheck source=lib/gst.sh
. "$SCRIPT_DIR/../lib/gst.sh"

require_env DEMO_PATH CLIP_NAME START_TICK END_TICK SPEC_SLOT

: "${CLIPS_DIR:=/mnt/game-streamer/clips}"
: "${CLIP_LEAD_SECONDS:=5}"
: "${CLIP_TAIL_SECONDS:=3}"

if [ ! -f "$DEMO_PATH" ]; then
  log "ERROR: demo file not found at $DEMO_PATH"
  exit 1
fi

# CS2 demo tickrate is 64.
TICKRATE=64
LEAD_TICKS=$(( CLIP_LEAD_SECONDS * TICKRATE ))
TAIL_TICKS=$(( CLIP_TAIL_SECONDS * TICKRATE ))
GOTO_TICK=$(( START_TICK - LEAD_TICKS ))
[ "$GOTO_TICK" -lt 0 ] && GOTO_TICK=0
STOP_TICK=$(( END_TICK + TAIL_TICKS ))
DURATION_SECS=$(( (STOP_TICK - GOTO_TICK) / TICKRATE + 2 ))

write_autoexec clip_autoexec \
  "sv_cheats 1" \
  "host_framerate $FPS" \
  "cl_drawhud 1" \
  "demo_pause 1" \
  "demo_gototick $GOTO_TICK" \
  "spec_player $SPEC_SLOT" \
  "demo_resume"

# Kill any prior cs2 + clear stale source-engine lock.
quit_cs2 hard

launch_cs2_via_steam \
  -fullscreen -width "$DISPLAY_SIZEW" -height "$DISPLAY_SIZEH" \
  -novid -nojoy -nohltv -console \
  +playdemo "$DEMO_PATH" \
  +exec clip_autoexec

wait_for_cs2_window 240

OUTPUT="$CLIPS_DIR/${CLIP_NAME}.mp4"
record_to_mp4 "$OUTPUT" "$DURATION_SECS"
log "clip written: $OUTPUT"

# Tear down CS2 — Job pod will exit shortly after.
quit_cs2

# TODO: re-add clip upload (will be a TypeScript service consuming
# rendered clips from $CLIPS_DIR — see future highlight pipeline).

log "render complete"
