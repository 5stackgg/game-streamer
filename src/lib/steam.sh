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

# Symlink ~/.local/share/Steam to a hostPath so login + downloaded games
# survive pod restarts.
persist_steam_state() {
  local target="$HOME/.local/share/Steam"
  local persist="$PERSIST_DIR/steam"
  mkdir -p "$persist"

  # Already correctly symlinked from a prior pod?
  if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$(readlink -f "$persist")" ]; then
    log "steam state already persisted at $persist"
    return 0
  fi

  # Migrate any pre-existing in-container state into the persist dir
  # (only on first run when persist is empty).
  if [ -d "$target" ] && [ ! -L "$target" ] \
       && [ -n "$(ls -A "$target" 2>/dev/null)" ] \
       && [ -z "$(ls -A "$persist" 2>/dev/null)" ]; then
    log "migrating $target → $persist"
    cp -a "$target/." "$persist/"
  fi
  rm -rf "$target" 2>/dev/null || true
  mkdir -p "$(dirname "$target")"
  ln -sfn "$persist" "$target"
  log "steam state persisted at $persist"
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

# steamcmd +app_update — uses real account when available (gets latest
# build), falls back to anonymous (older public branch only).
install_or_update_cs2() {
  log "checking CS2 (appid 730) install in $CS2_DIR"
  mkdir -p "$CS2_DIR"

  local login_args
  if [ -n "${STEAM_USER:-}" ] && [ -n "${STEAM_PASSWORD:-}" ]; then
    login_args=( +login "$STEAM_USER" "$STEAM_PASSWORD" )
  else
    log "  WARN: STEAM_USER/PASSWORD not set — using anonymous (may be stale)"
    login_args=( +login anonymous )
  fi

  /opt/steamcmd/steamcmd.sh \
    +@sSteamCmdForcePlatformType linux \
    +force_install_dir "$CS2_DIR" \
    "${login_args[@]}" \
    +app_update 730 validate \
    +quit

  if [ -f "$PERSIST_DIR/steamapps/appmanifest_730.acf" ]; then
    local bid
    bid=$(grep -oE '"buildid"[[:space:]]+"[0-9]+"' \
      "$PERSIST_DIR/steamapps/appmanifest_730.acf" | head -1)
    log "CS2 install OK — $bid"
  fi
}
