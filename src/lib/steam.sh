#!/usr/bin/env bash
# Steam client + library + session management.
# All functions are idempotent — safe to call on every container start.

# CS2 dlopens this exact path; symlink it to wherever steamclient.so is.
SDK64_LINK=/root/.steam/sdk64/steamclient.so

ensure_user_namespaces() {
  # Steam's pressure-vessel sandbox uses bwrap which requires user
  # namespaces. K8s pods need securityContext.privileged: true.
  if unshare -U /bin/true 2>/dev/null; then return 0; fi
  log "ERROR: user namespaces are DISABLED in this container."
  log "       Steam will hang silently. Fix by setting:"
  log "         spec.containers[].securityContext.privileged: true"
  log "       on the Deployment, then recreate the pod."
  return 1
}

# Symlink ~/.local/share/Steam (Steam client) AND ~/Steam (steamcmd home)
# to hostPath dirs so login tokens, downloaded games, and the Steam
# bootstrap survive pod restarts. After the first successful login, the
# session token is reused — no re-auth and no Steam Guard prompt.
persist_steam_state() {
  _persist_dir "$HOME/.local/share/Steam" "$PERSIST_DIR/steam"
  _persist_dir "$HOME/Steam"              "$PERSIST_DIR/steamcmd"
}

_persist_dir() {
  local target="$1" persist="$2"
  mkdir -p "$persist"

  if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$(readlink -f "$persist")" ]; then
    log "already persisted: $target → $persist"
    return 0
  fi

  # First run: migrate any in-container state into the persist dir.
  if [ -d "$target" ] && [ ! -L "$target" ] \
       && [ -n "$(ls -A "$target" 2>/dev/null)" ] \
       && [ -z "$(ls -A "$persist" 2>/dev/null)" ]; then
    log "migrating $target → $persist"
    cp -a "$target/." "$persist/"
  fi
  rm -rf "$target" 2>/dev/null || true
  mkdir -p "$(dirname "$target")"
  ln -sfn "$persist" "$target"
  log "persisted: $target → $persist"
}

# Register $PERSIST_DIR as a Steam library folder, write the marker file,
# and migrate any legacy +force_install_dir install into the proper Steam
# library layout so Steam's UI can launch it.
ensure_steam_library() {
  local lib="$PERSIST_DIR"
  local target="$lib/steamapps/common/Counter-Strike Global Offensive"
  local legacy="$lib/cs2"
  mkdir -p "$lib/steamapps/common"

  # Marker file telling Steam this directory IS a library folder.
  if [ ! -f "$lib/libraryfolder.vdf" ]; then
    cat > "$lib/libraryfolder.vdf" <<'EOF'
"libraryfolder"
{
    "contentid"        "0"
    "label"            ""
}
EOF
    log "wrote $lib/libraryfolder.vdf"
  fi

  # Register the library in Steam's libraryfolders.vdf (Steam scans this
  # at startup to find installed games).
  local vdf=/root/.local/share/Steam/config/libraryfolders.vdf
  mkdir -p "$(dirname "$vdf")"
  if [ ! -f "$vdf" ] || ! grep -q "\"path\"[[:space:]]*\"$lib\"" "$vdf"; then
    log "registering $lib in $vdf"
    if [ ! -f "$vdf" ]; then
      cat > "$vdf" <<EOF
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
        "apps" {}
    }
    "1"
    {
        "path"        "$lib"
        "label"       "game-streamer hostpath"
        "contentid"   "0"
        "totalsize"   "0"
        "update_clean_bytes_tally"   "0"
        "time_last_update_corruption"   "0"
        "apps" {}
    }
}
EOF
    else
      # Append a new indexed entry before the final closing brace.
      python3 - <<PY
import re, pathlib
p = pathlib.Path("$vdf")
src = p.read_text()
idxs = [int(m.group(1)) for m in re.finditer(r'"(\d+)"\s*\{', src)]
nxt = (max(idxs) + 1) if idxs else 0
entry = f'''
    "{nxt}"
    {{
        "path"        "$lib"
        "label"       "game-streamer hostpath"
        "contentid"   "0"
        "totalsize"   "0"
        "update_clean_bytes_tally"   "0"
        "time_last_update_corruption"   "0"
        "apps" {{}}
    }}
'''
src = src.rstrip()
if src.endswith("}"):
    src = src[:-1] + entry + "}\n"
p.write_text(src)
PY
    fi
  fi

  # Migrate legacy steamcmd-managed install layout into Steam-managed layout.
  if [ -d "$legacy" ] && [ ! -e "$target" ]; then
    log "migrating $legacy → $target"
    mv "$legacy" "$target"
  fi

  # Move manifest from legacy spot into the library's steamapps/.
  if [ -f "$target/steamapps/appmanifest_730.acf" ]; then
    mv "$target/steamapps/appmanifest_730.acf" "$lib/steamapps/appmanifest_730.acf"
    rmdir "$target/steamapps" 2>/dev/null || true
    log "moved appmanifest_730.acf into $lib/steamapps/"
  fi

  # Make sure the manifest's installdir matches the symlink/dir name.
  if [ -f "$lib/steamapps/appmanifest_730.acf" ]; then
    sed -i 's|"installdir"[[:space:]]*"[^"]*"|"installdir"\t\t"Counter-Strike Global Offensive"|' \
      "$lib/steamapps/appmanifest_730.acf"
  fi
}

# Symlink CS2's expected steamclient.so path to whichever copy Steam has
# already extracted. CS2 will FATAL without this.
ensure_steamclient() {
  if [ -L "$SDK64_LINK" ] && [ -e "$SDK64_LINK" ]; then return 0; fi
  mkdir -p "$(dirname "$SDK64_LINK")"
  local sc=""
  for d in \
      "$HOME/.local/share/Steam/linux64" \
      "$HOME/.steam/steam/linux64" \
      "$HOME/.steam/steamcmd/linux64" \
      "$HOME/Steam/linux64"; do
    if [ -f "$d/steamclient.so" ]; then sc="$d/steamclient.so"; break; fi
  done
  if [ -z "$sc" ]; then
    log "steamclient.so not found — bootstrapping steamcmd to produce it"
    /opt/steamcmd/steamcmd.sh +quit >/dev/null 2>&1 || true
    sc=$(find / -xdev -name 'steamclient.so' -path '*linux64*' 2>/dev/null | head -1)
  fi
  if [ -n "$sc" ]; then
    ln -sfn "$sc" "$SDK64_LINK"
    log "linked steamclient.so: $sc → $SDK64_LINK"
  else
    log "WARN: could not locate steamclient.so — CS2 will fail Steamworks init"
  fi
}

# Start the Steam client in the background, wait for its IPC pipe to come up.
# The cs2_servers account MUST have Steam Guard disabled.
start_steam() {
  if [ -p "$HOME/.steam/steam.pipe" ] && [ -f "$HOME/.steam/steam.pid" ] \
     && kill -0 "$(cat "$HOME/.steam/steam.pid" 2>/dev/null)" 2>/dev/null; then
    log "steam already running (pid $(cat "$HOME/.steam/steam.pid"))"
    return 0
  fi

  if [ -z "${STEAM_USER:-}" ] || [ -z "${STEAM_PASSWORD:-}" ]; then
    log "ERROR: STEAM_USER / STEAM_PASSWORD not set"
    return 1
  fi

  local steam_sh="$HOME/.local/share/Steam/steam.sh"
  if [ ! -x "$steam_sh" ]; then
    if [ -d /opt/steam-bootstrap ] && [ -x /opt/steam-bootstrap/steam.sh ]; then
      log "seeding Steam bootstrap from /opt/steam-bootstrap"
      cp -an /opt/steam-bootstrap/. "$HOME/.local/share/Steam/"
    fi
  fi
  if [ ! -x "$steam_sh" ]; then
    log "ERROR: $steam_sh missing — Steam bootstrap not extracted"
    return 1
  fi

  log "starting steam -silent -login $STEAM_USER"
  # dbus-launch gives Steam a session bus; --exit-with-session ties dbus
  # lifetime to steam.sh's. stdbuf line-buffers so [steam] log lines stream
  # in real time.
  (
    stdbuf -oL -eL dbus-launch --exit-with-session \
      "$steam_sh" -silent -login "$STEAM_USER" "$STEAM_PASSWORD" 2>&1 \
      | stdbuf -oL tee /tmp/steam.log \
      | sed -u 's/^/  [steam] /' >&2
  ) &

  for i in $(seq 1 180); do
    if [ -p "$HOME/.steam/steam.pipe" ] && [ -f "$HOME/.steam/steam.pid" ] \
       && kill -0 "$(cat "$HOME/.steam/steam.pid" 2>/dev/null)" 2>/dev/null; then
      log "steam IPC pipe up after ${i}s (pid $(cat "$HOME/.steam/steam.pid"))"
      return 0
    fi
    [ $(( i % 15 )) -eq 0 ] && log "  waiting for steam pipe (${i}s)"
    sleep 1
  done

  log "ERROR: steam pipe never appeared after 180s — last 30 lines:"
  tail -n 30 /mnt/game-streamer/steam/logs/console-linux.txt 2>/dev/null \
    | sed 's/^/  /' >&2 || true
  return 1
}

# Returns 0 if appmanifest_730.acf exists with StateFlags=4 (fully
# installed and current). Looks at both the legacy +force_install_dir
# location and the proper Steam library location.
cs2_is_installed() {
  local m
  for m in "$PERSIST_DIR/steamapps/appmanifest_730.acf" \
           "$CS2_DIR/steamapps/appmanifest_730.acf"; do
    if [ -f "$m" ]; then
      local flags
      flags=$(grep -oE '"StateFlags"[[:space:]]+"[0-9]+"' "$m" \
              | grep -oE '[0-9]+$' | head -1)
      [ "$flags" = "4" ] && return 0
    fi
  done
  return 1
}

# steamcmd +app_update — uses the real account when available (gets the
# latest build), falls back to anonymous (older public branch only).
#
# Skipped when CS2 is already fully installed in the persistent volume,
# which is the common case on every pod restart after first boot. Set
# CS2_FORCE_UPDATE=1 (or run `game-streamer.sh update-cs2`) to force.
install_or_update_cs2() {
  if [ "${CS2_FORCE_UPDATE:-0}" != "1" ] && cs2_is_installed; then
    local m="$PERSIST_DIR/steamapps/appmanifest_730.acf"
    [ -f "$m" ] || m="$CS2_DIR/steamapps/appmanifest_730.acf"
    local bid
    bid=$(grep -oE '"buildid"[[:space:]]+"[0-9]+"' "$m" | head -1)
    log "CS2 already installed — skipping steamcmd ($bid)"
    log "  force with CS2_FORCE_UPDATE=1 or 'game-streamer.sh update-cs2'"
    return 0
  fi

  log "running steamcmd +app_update 730 (install or update)"
  mkdir -p "$CS2_DIR"

  local login_args
  if [ -n "${STEAM_USER:-}" ] && [ -n "${STEAM_PASSWORD:-}" ]; then
    login_args=( +login "$STEAM_USER" "$STEAM_PASSWORD" )
  else
    log "  WARN: STEAM_USER/PASSWORD not set — using anonymous (may be stale)"
    login_args=( +login anonymous )
  fi

  local update_cmd="+app_update 730"
  [ -n "${CS2_BETA_BRANCH:-}" ] && update_cmd="$update_cmd -beta $CS2_BETA_BRANCH"
  update_cmd="$update_cmd validate"

  # shellcheck disable=SC2086 — $update_cmd is intentionally word-split.
  /opt/steamcmd/steamcmd.sh \
    +@sSteamCmdForcePlatformType linux \
    +force_install_dir "$CS2_DIR" \
    "${login_args[@]}" \
    $update_cmd \
    +quit

  if [ -f "$PERSIST_DIR/steamapps/appmanifest_730.acf" ]; then
    local bid
    bid=$(grep -oE '"buildid"[[:space:]]+"[0-9]+"' \
      "$PERSIST_DIR/steamapps/appmanifest_730.acf" | head -1)
    log "CS2 install OK — $bid"
  fi
}
