#!/usr/bin/env bash
# Reset CS2 install path: nuke the steamcmd-managed copy and register
# /mnt/game-streamer as a real Steam library folder so the Steam UI's
# Install dialog will let you target it (and the download persists across
# pod restarts on the hostPath).
#
# Steam must already be running (use run-steam-debug.sh start first).
#
# Usage:
#   ./scripts/setup-steam-library.sh

set -uo pipefail

: "${DISPLAY:=:0}"
LIBRARY_DIR=/mnt/game-streamer

say() { printf '\n=== %s ===\n' "$*"; }

say "1. stop any cs2 + open install dialog"
pkill -9 -f '/linuxsteamrt64/cs2' 2>/dev/null || true
# also dismiss the open install dialog so we don't trigger a download to
# the wrong place
WIN=$(xwininfo -display "$DISPLAY" -root -tree 2>/dev/null \
       | awk '/"Install"/{print $1; exit}')
if [ -n "$WIN" ]; then
  echo "  closing existing install dialog $WIN"
  xdotool key --window "$WIN" Escape 2>/dev/null || true
fi
sleep 1

say "2. nuke steamcmd-managed CS2 install + manifest hacks"
rm -f /root/.local/share/Steam/steamapps/appmanifest_730.acf
rm -f "/root/.local/share/Steam/steamapps/common/Counter-Strike Global Offensive"
echo "  removed manifest + symlink from default library"
# WARNING: the actual CS2 files at /mnt/game-streamer/cs2 are 60GB.
# We'll move them into the proper Steam library structure below — keep them.

say "3. register /mnt/game-streamer as a Steam library folder"
mkdir -p "$LIBRARY_DIR/steamapps/common"

# libraryfolder.vdf in the library root tells Steam this dir IS a library
cat > "$LIBRARY_DIR/libraryfolder.vdf" <<'EOF'
"libraryfolder"
{
    "contentid"        "0"
    "label"            ""
}
EOF
echo "  wrote $LIBRARY_DIR/libraryfolder.vdf"

# add the library to Steam's libraryfolders.vdf
LF=/root/.local/share/Steam/config/libraryfolders.vdf
mkdir -p "$(dirname "$LF")"
if [ ! -f "$LF" ]; then
  cat > "$LF" <<EOF
"libraryfolders"
{
    "0"
    {
        "path"        "/root/.local/share/Steam"
        "label"       ""
        "contentid"   "0"
        "totalsize"   "0"
        "update_clean_bytes_tally"   "0"
        "time_last_update_corruption"   "0"
    }
    "1"
    {
        "path"        "$LIBRARY_DIR"
        "label"       "game-streamer hostpath"
        "contentid"   "0"
        "totalsize"   "0"
        "update_clean_bytes_tally"   "0"
        "time_last_update_corruption"   "0"
    }
}
EOF
  echo "  wrote fresh $LF with /mnt/game-streamer registered"
else
  if ! grep -q "$LIBRARY_DIR" "$LF"; then
    echo "  appending $LIBRARY_DIR to existing $LF (manual edit may be needed)"
    # Best-effort sed insert — works on the simple Steam-generated layout.
    # Find the last `}` of the libraryfolders block and inject another entry.
    python3 - <<PY
import re, pathlib
p = pathlib.Path("$LF")
src = p.read_text()
# count existing top-level entries to assign next index
idxs = [int(m.group(1)) for m in re.finditer(r'"(\d+)"\s*\{', src)]
nxt = max(idxs) + 1 if idxs else 0
entry = f'''
    "{nxt}"
    {{
        "path"        "$LIBRARY_DIR"
        "label"       "game-streamer hostpath"
        "contentid"   "0"
        "totalsize"   "0"
        "update_clean_bytes_tally"   "0"
        "time_last_update_corruption"   "0"
    }}
'''
# inject before final closing brace
src = src.rstrip()
if src.endswith("}"):
    src = src[:-1] + entry + "}\n"
p.write_text(src)
print(f"  appended entry {nxt}")
PY
  else
    echo "  $LIBRARY_DIR already in $LF — no change"
  fi
fi

say "4. moving existing CS2 files into the new library layout"
TARGET_DIR="$LIBRARY_DIR/steamapps/common/Counter-Strike Global Offensive"
SOURCE_DIR="$LIBRARY_DIR/cs2"
if [ -d "$SOURCE_DIR" ] && [ ! -e "$TARGET_DIR" ]; then
  echo "  moving $SOURCE_DIR -> $TARGET_DIR (rename, fast)"
  mv "$SOURCE_DIR" "$TARGET_DIR"
elif [ -e "$TARGET_DIR" ]; then
  echo "  $TARGET_DIR already exists — leaving alone"
else
  echo "  no $SOURCE_DIR to move (already moved or never installed)"
fi

# move the manifest into the library's steamapps/
if [ -f "$TARGET_DIR/steamapps/appmanifest_730.acf" ]; then
  mv "$TARGET_DIR/steamapps/appmanifest_730.acf" \
     "$LIBRARY_DIR/steamapps/appmanifest_730.acf"
  rmdir "$TARGET_DIR/steamapps" 2>/dev/null || true
  # fix installdir field
  sed -i 's|"installdir"[[:space:]]*"[^"]*"|"installdir"\t\t"Counter-Strike Global Offensive"|' \
    "$LIBRARY_DIR/steamapps/appmanifest_730.acf"
  echo "  moved manifest to $LIBRARY_DIR/steamapps/ + fixed installdir"
fi

say "5. update CS2_DIR for our scripts"
echo "  point env: export CS2_DIR=\"$TARGET_DIR\""
echo "  (and update game-streamer-config.env if you want this permanent)"

say "6. restart Steam so it rescans library folders"
pkill -9 -f '/steam.sh\|/ubuntu12_32/steam\|steamwebhelper\|dbus-launch' 2>/dev/null || true
sleep 3
/opt/5stack/scripts/run-steam-debug.sh start

say "done"
echo ""
echo "  next: try -applaunch via run-live-debug.sh."
echo "  CS2 should now be visible in Steam's library on /mnt/game-streamer."
echo "  If Steam pops the Install dialog, the new dir should show as an option."
