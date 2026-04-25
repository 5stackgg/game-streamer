#!/usr/bin/env bash
# One-shot CS2 crash debugger. Launches CS2 directly (not via live.sh so
# the GStreamer pipe doesn't steal stderr), waits for the segfault, then
# finds the core dump and prints a gdb backtrace.
#
# Requires: $CONNECT_ADDR, $CONNECT_PASSWORD, $MATCH_ID already exported.
#
# Usage:
#   ./debug-cs2-crash.sh

set -uo pipefail

: "${CONNECT_ADDR:?set CONNECT_ADDR}"
: "${CONNECT_PASSWORD:?set CONNECT_PASSWORD}"
: "${CS2_DIR:=/mnt/game-streamer/steamapps/common/Counter-Strike Global Offensive}"
: "${DISPLAY:=:0}"
: "${XDG_RUNTIME_DIR:=/tmp/xdg-runtime-root}"

mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"

say() { printf '\n=== %s ===\n' "$*"; }

say "1. preparing core dump capture"
# bypass apport; drop core files in /tmp as plain core.<pid>
echo '/tmp/core.%e.%p' >/proc/sys/kernel/core_pattern 2>/dev/null || \
  echo 'core' >/proc/sys/kernel/core_pattern
ulimit -c unlimited
echo "core_pattern: $(cat /proc/sys/kernel/core_pattern)"
echo "ulimit -c:    $(ulimit -c)"
rm -f /tmp/core.*

say "2. killing any prior cs2 / stale locks"
pkill -9 -f '/linuxsteamrt64/cs2' 2>/dev/null || true
sleep 1
rm -f /tmp/source_engine_*.lock

say "3. sanity checks"
echo "STEAMCLIENT.so -> $(readlink /root/.steam/sdk64/steamclient.so)"
echo "steam_appid.txt:"
ls /mnt/game-streamer/steamapps/common/Counter-Strike Global Offensive/game/csgo/steam_appid.txt \
   /mnt/game-streamer/steamapps/common/Counter-Strike Global Offensive/game/bin/linuxsteamrt64/steam_appid.txt 2>/dev/null
echo "gbe_fork steam_settings:"
ls /opt/gbe_fork/steam_settings 2>/dev/null | head -5 || echo "  not configured"

say "4. launching CS2 directly (no GStreamer wrapper)"
CS2_BIN="$CS2_DIR/game/bin/linuxsteamrt64/cs2"
cd "$(dirname "$CS2_BIN")"
LD_LIBRARY_PATH="$CS2_DIR/game/bin/linuxsteamrt64:${LD_LIBRARY_PATH:-}" \
"$CS2_BIN" \
  -fullscreen -width 1920 -height 1080 -novid -nojoy \
  +password "$CONNECT_PASSWORD" \
  +connect "$CONNECT_ADDR" \
  >/tmp/cs2.log 2>&1
CS2_EXIT=$?
echo "CS2 exited with status $CS2_EXIT"

say "5. cs2 log tail"
tail -40 /tmp/cs2.log

say "6. looking for core file"
# core dropped wherever CS2 was running from — we cd'd, so try there AND /tmp
CORE=$(ls -t /tmp/core.* 2>/dev/null | head -1)
[ -z "$CORE" ] && CORE=$(ls -t ./core* 2>/dev/null | head -1)
[ -z "$CORE" ] && CORE=$(find / -xdev -type f \( -name 'core' -o -name 'core.*' \) -mmin -3 -size +100k 2>/dev/null | head -1)

if [ -z "$CORE" ]; then
  echo "no core file found. sometimes apport still intercepts — check:"
  echo "  cat /proc/sys/kernel/core_pattern"
  cat /proc/sys/kernel/core_pattern
  echo "  ls /var/crash/ 2>/dev/null:"
  ls /var/crash/ 2>/dev/null | head
  exit 1
fi

echo "core: $CORE ($(du -h "$CORE" | cut -f1))"

say "7. gdb backtrace of the crashing thread"
if ! command -v gdb >/dev/null 2>&1; then
  echo "gdb not installed — falling back to strace approach"
  exit 1
fi
gdb --batch --quiet \
  -ex 'set pagination off' \
  -ex 'bt' \
  -ex 'info registers' \
  -ex 'thread apply all bt 20' \
  "$CS2_BIN" "$CORE" 2>&1 | tail -120
