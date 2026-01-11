#!/usr/bin/env bash
# Cleanly stop CS2 + the GStreamer capture stream.
# Doesn't touch Steam, Xorg, or openbox.
#
# Usage:
#   ./scripts/quit-cs2.sh           # kill CS2 + any GStreamer capture
#   ./scripts/quit-cs2.sh hard      # also wipe stale lock files

set -uo pipefail

MODE="${1:-}"

echo "[quit-cs2] killing cs2 process(es)"
pkill -TERM -f '/linuxsteamrt64/cs2' 2>/dev/null || true
sleep 2
# nuke any survivors
pkill -KILL -f '/linuxsteamrt64/cs2' 2>/dev/null || true

echo "[quit-cs2] killing any GStreamer publish streams"
pkill -TERM -f 'gst-launch.*publish:' 2>/dev/null || true
sleep 1
pkill -KILL -f 'gst-launch.*publish:' 2>/dev/null || true

if [ "$MODE" = "hard" ]; then
  echo "[quit-cs2] hard mode — clearing lock files"
  rm -f /tmp/source_engine_*.lock 2>/dev/null || true
  rm -f /tmp/.X*-lock 2>/dev/null || true
fi

echo "[quit-cs2] done"
echo "  remaining processes:"
pgrep -af 'cs2|gst-launch' | grep -v 'quit-cs2\|pgrep' | sed 's/^/    /' || echo "    (none)"
