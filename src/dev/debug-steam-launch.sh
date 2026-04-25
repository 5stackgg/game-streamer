#!/usr/bin/env bash
# One-shot diagnostic for "Steam IPC accepts -applaunch but never spawns CS2".
# Inspects what Steam thinks it knows, then tries the steam:// URL handlers
# to force-trigger the launch / install dialog.
#
# Usage:
#   ./debug-steam-launch.sh

set -uo pipefail

: "${DISPLAY:=:0}"
STEAM_BIN=/root/.local/share/Steam/ubuntu12_32/steam

say() { printf '\n=== %s ===\n' "$*"; }

# ----------------------------------------------------------------------
say "1. Steam process state"
if pgrep -f '/ubuntu12_32/steam' >/dev/null 2>&1; then
  echo "  Steam IS running"
  if [ -p "$HOME/.steam/steam.pipe" ] \
     && [ -f "$HOME/.steam/steam.pid" ] \
     && kill -0 "$(cat "$HOME/.steam/steam.pid")" 2>/dev/null; then
    echo "  PIPE UP (pid $(cat "$HOME/.steam/steam.pid"))"
  else
    echo "  WARN: pipe is stale"
  fi
else
  echo "  ERROR: Steam not running. Start with /opt/game-streamer/src/game-streamer.sh start"
  exit 1
fi

# ----------------------------------------------------------------------
say "2. Steam's library folders"
for f in /root/.local/share/Steam/config/libraryfolders.vdf \
         /root/.local/share/Steam/steamapps/libraryfolders.vdf; do
  if [ -f "$f" ]; then
    echo "--- $f ---"
    cat "$f" | sed 's/^/  /'
  fi
done

# ----------------------------------------------------------------------
say "3. Manifest in Steam's default library"
if [ -f /root/.local/share/Steam/steamapps/appmanifest_730.acf ]; then
  echo "  exists. installdir + StateFlags + LastOwner:"
  grep -E 'installdir|StateFlags|LastOwner|buildid' \
    /root/.local/share/Steam/steamapps/appmanifest_730.acf | sed 's/^/    /'
else
  echo "  MISSING — Steam can't see CS2 as installed"
fi

say "4. CS2 install symlink"
LINK="/root/.local/share/Steam/steamapps/common/Counter-Strike Global Offensive"
if [ -L "$LINK" ]; then
  echo "  exists -> $(readlink "$LINK")"
  echo "  cs2 binary: $([ -x "$LINK/game/bin/linuxsteamrt64/cs2" ] && echo present || echo MISSING)"
else
  echo "  MISSING symlink"
fi

# ----------------------------------------------------------------------
say "5. user account info (loginusers.vdf)"
if [ -f /root/.local/share/Steam/config/loginusers.vdf ]; then
  cat /root/.local/share/Steam/config/loginusers.vdf | sed 's/^/  /'
fi

# ----------------------------------------------------------------------
say "6. trying steam://install/730 (forces Steam to acknowledge CS2)"
echo "  watch https://hls.5stack.gg/debug/ for an Install/Play dialog"
"$STEAM_BIN" steam://install/730 >/tmp/steam_install_url.log 2>&1 &
sleep 5

say "7. windows visible right now"
xwininfo -display "$DISPLAY" -root -tree 2>/dev/null \
  | grep -E '"[^"]+"' | head -30 | sed 's/^/  /'

# ----------------------------------------------------------------------
say "8. trying steam://run/730 (asks Steam to launch CS2)"
"$STEAM_BIN" steam://run/730 >/tmp/steam_run_url.log 2>&1 &
echo "  waiting 30s for cs2 process to appear..."
for i in $(seq 1 30); do
  CS2_PID=$(pgrep -f '/linuxsteamrt64/cs2' | head -1)
  [ -n "$CS2_PID" ] && { echo "  CS2 STARTED — pid $CS2_PID"; break; }
  sleep 1
done
[ -z "${CS2_PID:-}" ] && echo "  CS2 still didn't start"

# ----------------------------------------------------------------------
say "9. final state"
echo "  cs2 process:"
pgrep -af '/linuxsteamrt64/cs2' | sed 's/^/    /' || echo "    (none)"
echo "  windows:"
xwininfo -display "$DISPLAY" -root -tree 2>/dev/null \
  | grep -E '"[^"]+"' | head -20 | sed 's/^/    /'
echo "  recent steam log:"
tail -20 /mnt/game-streamer/steam/logs/console-linux.txt 2>/dev/null | sed 's/^/    /'

say "done"
echo "  if no Install dialog appeared in step 6 and no CS2 in step 8,"
echo "  the account doesn't recognize CS2 as installed/owned —"
echo "  next step is to drive Steam UI to add CS2 to library."
