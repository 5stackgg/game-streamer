#!/usr/bin/env bash
# Update / validate the CS2 install in /mnt/game-streamer/cs2 via
# authenticated steamcmd. Authenticated download is required to get the
# *latest* CS2 build — anonymous only ships an older publicly-redistributable
# version.
#
# Required env (already in pod from secrets):
#   STEAM_USERNAME
#   STEAM_PASSWORD
#
# Optional env:
#   CS2_BETA_BRANCH    e.g. "prerelease"  (omit for default public branch)
#
# Usage:
#   ./scripts/update-cs2.sh           # update + validate
#   ./scripts/update-cs2.sh quick     # update without validate (faster)

set -euo pipefail

: "${STEAM_USERNAME:?set STEAM_USERNAME}"
: "${STEAM_PASSWORD:?set STEAM_PASSWORD}"
: "${CS2_DIR:=/mnt/game-streamer/cs2}"

MODE="${1:-validate}"

say() { printf '\n=== %s ===\n' "$*"; }

# Make sure CS2 isn't running so steamcmd can rewrite files.
if pgrep -f '/linuxsteamrt64/cs2' >/dev/null 2>&1; then
  say "CS2 is running — stopping first"
  pkill -TERM -f '/linuxsteamrt64/cs2' 2>/dev/null || true
  sleep 2
  pkill -KILL -f '/linuxsteamrt64/cs2' 2>/dev/null || true
fi

say "BEFORE"
if [ -f "$CS2_DIR/steamapps/appmanifest_730.acf" ]; then
  grep -i 'BuildID\|TargetBuildID\|StateFlags' "$CS2_DIR/steamapps/appmanifest_730.acf" | sed 's/^/  /'
else
  echo "  no install yet at $CS2_DIR"
fi

# Build steamcmd args.
ARGS=(
  +@sSteamCmdForcePlatformType linux
  +force_install_dir "$CS2_DIR"
  +login "$STEAM_USERNAME" "$STEAM_PASSWORD"
)

UPDATE_CMD="+app_update 730"
[ -n "${CS2_BETA_BRANCH:-}" ] && UPDATE_CMD="$UPDATE_CMD -beta $CS2_BETA_BRANCH"
[ "$MODE" = "validate" ] && UPDATE_CMD="$UPDATE_CMD validate"

say "RUNNING: $UPDATE_CMD"
# Call steamcmd.sh directly — the /usr/local/bin/steamcmd shim resolves
# its own path wrong via symlink.
/opt/steamcmd/steamcmd.sh "${ARGS[@]}" $UPDATE_CMD +quit

say "AFTER"
grep -i 'BuildID\|TargetBuildID\|StateFlags' "$CS2_DIR/steamapps/appmanifest_730.acf" | sed 's/^/  /'

say "LATEST AVAILABLE (public branch)"
/opt/steamcmd/steamcmd.sh \
  +login "$STEAM_USERNAME" "$STEAM_PASSWORD" \
  +app_info_update 1 \
  +app_info_print 730 \
  +quit 2>/dev/null \
  | grep -A2 '"public"' | head -10 | sed 's/^/  /'

say "done"
echo "  if BuildID still differs from your game-server, set CS2_BETA_BRANCH"
echo "  e.g. CS2_BETA_BRANCH=prerelease /opt/5stack/scripts/update-cs2.sh"
