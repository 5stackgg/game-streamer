#!/usr/bin/env bash
# One-stop state / reset helper for the game-streamer pod.
# No args required. Just run.
#
# Commands:
#   ./scripts/state.sh            # show status
#   ./scripts/state.sh status     # same
#   ./scripts/state.sh reset      # kill everything + wipe steam/cs2 temp state
#   ./scripts/state.sh logs       # tail the important logs
#   ./scripts/state.sh dismiss    # click/press Return on any blocking dialog

set -uo pipefail

: "${DISPLAY:=:0}"

say()  { printf '\n=== %s ===\n' "$*"; }
line() { printf -- '---\n'; }

cmd_status() {
  say "PROCESSES"
  local any=0
  for pat in '/linuxsteamrt64/cs2' 'ubuntu12_32/steam' 'steamwebhelper' '/steam\.sh' 'Xorg' 'openbox' 'gst-launch'; do
    local hits
    hits=$(pgrep -af "$pat" 2>/dev/null | grep -v "pgrep\|state\.sh" || true)
    if [ -n "$hits" ]; then
      any=1
      printf '  %-22s %s\n' "$pat:" ""
      printf '      %s\n' "$hits" | sed 's/^      /      /'
    fi
  done
  [ $any -eq 0 ] && echo "  (nothing relevant running)"

  say "XORG"
  if DISPLAY="$DISPLAY" xdpyinfo >/dev/null 2>&1; then
    echo "  display $DISPLAY: UP"
  else
    echo "  display $DISPLAY: DOWN"
  fi

  say "X WINDOWS"
  if DISPLAY="$DISPLAY" xwininfo >/dev/null 2>&1 -root; then
    DISPLAY="$DISPLAY" xwininfo -root -tree 2>/dev/null \
      | grep -E '"[^"]+"' | sed 's/^[[:space:]]*/  /'
  else
    echo "  (X not reachable)"
  fi

  say "STEAM IPC"
  local pipe="$HOME/.steam/steam.pipe"
  local pid_file="$HOME/.steam/steam.pid"
  if [ -p "$pipe" ] && [ -f "$pid_file" ]; then
    local pid; pid=$(cat "$pid_file")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "  PIPE UP (pid $pid alive)"
    else
      echo "  pipe file exists but Steam pid $pid is DEAD (stale)"
    fi
  else
    echo "  no pipe file — Steam has never fully started this pod"
  fi

  say "DUMP / LOCK FILES"
  ls -la /tmp/dumps* /tmp/source_engine_*.lock /mnt/game-streamer/steam/.crash 2>/dev/null \
    | sed 's/^/  /' || echo "  (none)"

  say "HLS STREAM"
  echo "  watch at: https://hls.5stack.gg/debug/   (if debug-steam-login.sh start is running)"
  echo "  watch at: https://hls.5stack.gg/<MATCH_ID>/   (if live.sh is running)"

  say "LATEST LOGS (last 5 lines each)"
  for f in /tmp/steam_manual.log /tmp/cs2.log /tmp/xorg.log /mnt/game-streamer/steam/logs/console-linux.txt; do
    if [ -f "$f" ]; then
      printf -- '--- %s ---\n' "$f"
      tail -5 "$f" 2>/dev/null | sed 's/^/  /'
    fi
  done
}

cmd_reset() {
  say "RESET: killing processes"
  pkill -9 -f '/linuxsteamrt64/cs2'  2>/dev/null || true
  pkill -9 -f 'ubuntu12_32/steam'    2>/dev/null || true
  pkill -9 -f 'steamwebhelper'       2>/dev/null || true
  pkill -9 -f '/steam.sh'            2>/dev/null || true
  pkill -9 -x steam                  2>/dev/null || true
  pkill -9 -x zenity                 2>/dev/null || true
  pkill -9 -x dbus-launch            2>/dev/null || true
  pkill -9 -f 'gst-launch'           2>/dev/null || true
  sleep 1

  say "RESET: clearing temp state"
  rm -rf /tmp/dumps* /tmp/source_engine_*.lock /tmp/steam_pipe_* 2>/dev/null || true
  rm -f  /mnt/game-streamer/steam/.crash 2>/dev/null || true
  rm -f  "$HOME/.steam/steam.pid" "$HOME/.steam/steam.pipe" "$HOME/.steam/steam.token" 2>/dev/null || true

  say "RESET: done"
  echo "  Xorg/openbox left alone (cheap to restart if you need to)."
  echo "  To relaunch Steam:  ./scripts/debug-steam-login.sh start"
  echo "  To relaunch CS2:    ./scripts/live.sh   (needs MATCH_ID + CONNECT_ADDR env)"
}

cmd_logs() {
  for f in /tmp/steam_manual.log /tmp/cs2.log /tmp/xorg.log /mnt/game-streamer/steam/logs/console-linux.txt; do
    if [ -f "$f" ]; then
      say "TAIL: $f"
      tail -30 "$f" 2>/dev/null | sed 's/^/  /'
    fi
  done
}

cmd_dismiss() {
  say "DISMISS: pressing Return on blocking dialogs"
  local found=0
  for name in 'Launcher Error' 'FATAL' 'Steam installer' 'Question' 'Setup' 'Error'; do
    local ids
    ids=$(DISPLAY="$DISPLAY" xdotool search --name "$name" 2>/dev/null || true)
    [ -z "$ids" ] && continue
    for id in $ids; do
      echo "  dismissing '$name' window $id"
      DISPLAY="$DISPLAY" xdotool key --window "$id" Return 2>/dev/null || true
      DISPLAY="$DISPLAY" xdotool key --window "$id" Escape 2>/dev/null || true
      found=1
    done
  done
  [ $found -eq 0 ] && echo "  (nothing to dismiss)"
}

cmd_libs() {
  say "PANGO / GTK VERSIONS"
  dpkg -l 2>/dev/null | grep -Ei 'pango|gtk|harfbuzz|freetype' | awk '{print "  " $2, $3}'

  say "SYMBOL CHECK: pango_font_family_get_face"
  if nm -D /usr/lib/x86_64-linux-gnu/libpango-1.0.so.0 2>/dev/null \
       | grep -q pango_font_family_get_face; then
    echo "  OK — symbol present in libpango-1.0.so.0"
  else
    echo "  MISSING from system libpango-1.0.so.0"
    echo "  -> this is why zenity (and probably Steam's UI) crashes"
  fi

  say "SYMBOL CHECK in sniper runtime's pango"
  if [ -f /root/.local/share/Steam/ubuntu12_32/steam-runtime/usr/lib/x86_64-linux-gnu/libpango-1.0.so.0 ]; then
    nm -D /root/.local/share/Steam/ubuntu12_32/steam-runtime/usr/lib/x86_64-linux-gnu/libpango-1.0.so.0 2>/dev/null \
      | grep -q pango_font_family_get_face \
      && echo "  OK in runtime pango" \
      || echo "  MISSING in runtime pango too"
  fi

  say "ZENITY SMOKE TEST"
  if DISPLAY="$DISPLAY" timeout 3 zenity --info --text=hi --timeout=1 2>&1 | head -3; then
    :
  fi
}

case "${1:-status}" in
  status|'')   cmd_status ;;
  reset)       cmd_reset ;;
  logs)        cmd_logs ;;
  dismiss)     cmd_dismiss ;;
  libs)        cmd_libs ;;
  help|-h|--help)
    grep '^# ' "$0" | sed 's/^# //'
    ;;
  *) echo "unknown: $1"; echo "try: status | reset | logs | dismiss | libs"; exit 2 ;;
esac
