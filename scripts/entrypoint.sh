#!/usr/bin/env bash
set -euo pipefail

log() { echo "[entrypoint] $*"; }

# Resolve everything relative to this script so the whole tree can be moved,
# synced, or symlinked without breaking.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export SCRIPT_DIR REPO_DIR

: "${MODE:=idle}"
# Only CS2 data lives at a fixed path — it's the large, shared, host-mounted
# cache. Everything else is relative to $SCRIPT_DIR.
: "${CS2_DIR:=/mnt/game-streamer/steamapps/common/Counter-Strike Global Offensive}"
: "${DISPLAY:=:0}"
: "${DISPLAY_SIZEW:=1920}"
: "${DISPLAY_SIZEH:=1080}"
: "${FPS:=60}"
: "${XDG_RUNTIME_DIR:=/tmp/xdg-runtime-$(id -u)}"

# CS2/Source 2 uses XDG_RUNTIME_DIR for ipc sockets; must exist with 0700.
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

export DISPLAY CS2_DIR XDG_RUNTIME_DIR

start_openbox() {
  # Lightweight WM so xdotool windowactivate / _NET_ACTIVE_WINDOW work —
  # required for auto-dismissing Steam's first-run zenity dialog.
  if pgrep -x openbox >/dev/null 2>&1; then return 0; fi
  if command -v openbox >/dev/null 2>&1; then
    DISPLAY="$DISPLAY" nohup openbox >/tmp/openbox.log 2>&1 &
    sleep 1
    log "openbox started"
  fi
}

start_xorg() {
  # Already running? Reuse it — makes this script safe to re-run inside an
  # existing pod (e.g. from a codepier shell). pgrep is more reliable than
  # xdpyinfo because it doesn't depend on X cookies being in scope.
  if pgrep -x Xorg >/dev/null 2>&1; then
    log "Xorg already running — reusing"
    start_openbox
    return 0
  fi

  # Clean stale lock/socket from a previous crashed Xorg.
  local n="${DISPLAY#:}"
  rm -f "/tmp/.X${n}-lock" "/tmp/.X11-unix/X${n}" 2>/dev/null || true

  log "Starting Xorg on $DISPLAY"
  # -listen unix forces Xorg to create the filesystem socket at
  # /tmp/.X11-unix/X0 in addition to the abstract socket. Steam's bundled
  # 32-bit libX11 only looks at the filesystem path; without this it fails
  # XOpenDisplay and the main client segfaults.
  # -config must be a bare filename when Xorg is setuid (Xorg.wrap).
  Xorg "$DISPLAY" -config xorg-dummy.conf \
    -noreset -nolisten tcp -listen unix vt7 >/tmp/xorg.log 2>&1 &
  XORG_PID=$!
  echo $XORG_PID >/tmp/xorg.pid

  for _ in $(seq 1 30); do
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
      log "Xorg up on $DISPLAY"
      # Open X access so Steam (pressure-vessel, separate process) can
      # connect — without this its main client segfaults on "Unable to
      # open display" even though we pass DISPLAY=:0.
      xhost +local: >/dev/null 2>&1 || true
      xhost +SI:localuser:root >/dev/null 2>&1 || true
      start_openbox
      return 0
    fi
    sleep 0.5
  done
  log "ERROR: Xorg did not come up"
  for f in /var/log/Xorg.0.log /home/app/.local/share/xorg/Xorg.0.log /tmp/xorg.log; do
    if [ -f "$f" ]; then
      log "--- $f ---"
      tail -n 80 "$f" >&2 || true
    fi
  done
  # Don't exit in idle mode — keep the pod alive for debugging.
  if [ "$MODE" = "idle" ]; then
    log "idle mode — keeping pod up despite Xorg failure; investigate /tmp/xorg.log"
    return 1
  fi
  exit 1
}

install_cs2() {
  # Always check/update on boot. Anonymous login only ships an older
  # publicly-redistributable CS2 build; use the real account when available
  # so we get the latest version that matches the game-server.
  log "Installing/updating CS2 (appid 730) into $CS2_DIR via steamcmd"
  mkdir -p "$CS2_DIR"

  local login_args
  if [ -n "${STEAM_USERNAME:-}" ] && [ -n "${STEAM_PASSWORD:-}" ]; then
    log "  using authenticated login ($STEAM_USERNAME) — gets latest build"
    login_args=( +login "$STEAM_USERNAME" "$STEAM_PASSWORD" )
  else
    log "  WARN: no STEAM_USERNAME/STEAM_PASSWORD — using anonymous (may be stale)"
    login_args=( +login anonymous )
  fi

  # Call steamcmd.sh directly — the /usr/local/bin/steamcmd shim resolves
  # its own dir wrong when invoked via symlink and can't find linux32/.
  /opt/steamcmd/steamcmd.sh \
    +@sSteamCmdForcePlatformType linux \
    +force_install_dir "$CS2_DIR" \
    "${login_args[@]}" \
    +app_update 730 validate \
    +quit

  if [ -f "$CS2_DIR/steamapps/appmanifest_730.acf" ]; then
    local bid
    bid=$(grep -oE '"buildid"[[:space:]]+"[0-9]+"' "$CS2_DIR/steamapps/appmanifest_730.acf" | head -1)
    log "CS2 install complete — $bid"
  else
    log "CS2 install complete (no manifest found)"
  fi
}

ensure_steamclient() {
  # CS2 dlopens ~/.steam/sdk64/steamclient.so. Point it at whichever copy
  # steamcmd/steam has bootstrapped. Idempotent.
  local link="$HOME/.steam/sdk64/steamclient.so"
  if [ -L "$link" ] && [ -e "$link" ]; then return 0; fi
  mkdir -p "$(dirname "$link")"
  local sc=""
  # Check all the places steamcmd/steam might drop it.
  for d in \
      "$HOME/.local/share/Steam/linux64" \
      "$HOME/.steam/steam/linux64" \
      "$HOME/.steam/steamcmd/linux64" \
      "$HOME/Steam/linux64" \
      /root/.steam/steam/linux64; do
    if [ -f "$d/steamclient.so" ]; then sc="$d/steamclient.so"; break; fi
  done
  if [ -z "$sc" ]; then
    log "steamclient.so not found — bootstrapping steamcmd"
    steamcmd +quit >/dev/null 2>&1 || true
    sc=$(find / -xdev -name 'steamclient.so' -path '*linux64*' 2>/dev/null | head -1)
  fi
  if [ -n "$sc" ]; then
    ln -sfn "$sc" "$link"
    log "linked steamclient.so: $sc -> $link"
  else
    log "WARN: could not locate steamclient.so; CS2 will fail Steamworks init"
  fi
}

# Resolve the steam launcher. Prefer the bootstrap's own steam.sh (no
# zenity), fall back to /usr/games/steam shim if the bootstrap isn't present.
find_steam_bin() {
  for p in \
      "$HOME/.local/share/Steam/steam.sh" \
      /usr/games/steam \
      /usr/bin/steam \
      /usr/local/bin/steam; do
    [ -x "$p" ] && { echo "$p"; return 0; }
  done
  command -v steam 2>/dev/null && return 0
  return 1
}

# Persist the Steam session cache (config.vdf machine token, saved login)
# to the hostPath. Only touch ~/.local/share/Steam — that's where Steam
# actually stores persistent state. ~/.steam is mostly symlinks into it
# plus sdk64/steamclient.so baked at image build time, which we must NOT
# overwrite.
persist_steam_state() {
  local persist="/mnt/game-streamer/steam"
  local target="$HOME/.local/share/Steam"
  mkdir -p "$persist"

  # Legacy cleanup: an earlier version symlinked $HOME/.steam at
  # $persist/dot-steam, which shadowed the baked sdk64/steamclient.so.
  if [ -L "$HOME/.steam" ]; then
    local tgt
    tgt=$(readlink "$HOME/.steam" 2>/dev/null || true)
    if [[ "$tgt" == "$persist"* ]]; then
      log "removing legacy ~/.steam symlink ($tgt)"
      rm -f "$HOME/.steam"
    fi
  fi
  rm -rf "$persist/dot-steam" 2>/dev/null || true

  if [ -L "$target" ]; then
    # Already symlinked — assume prior pod wired things up correctly.
    log "steam state already persisted at $persist"
    return 0
  fi

  if [ -d "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
    # Real dir with content. Migrate into persist — but only if persist
    # is empty (don't clobber accumulated Steam state).
    if [ -z "$(ls -A "$persist" 2>/dev/null)" ]; then
      log "migrating existing Steam state -> $persist"
      cp -a "$target/." "$persist/"
      rm -rf "$target"
    else
      # Both exist with content — prefer persist. Back up target.
      log "both \$target and \$persist have content; backing up target and using persist"
      mv "$target" "$target.bak.$(date +%s)"
    fi
  else
    # Empty or missing target — just remove it to make way for the symlink.
    rm -rf "$target" 2>/dev/null || true
  fi
  mkdir -p "$(dirname "$target")"
  ln -sfn "$persist" "$target"
  log "steam state persisted at $persist"
}

check_user_namespaces() {
  # Steam (current client) sandboxes via bwrap / pressure-vessel and
  # requires unprivileged user namespaces. Fail loud if the pod is too
  # locked down — otherwise steam hangs silently at "runtime up-to-date".
  if unshare -U /bin/true 2>/dev/null; then
    return 0
  fi
  log "ERROR: user namespaces are DISABLED in this container."
  log "       Steam requires them (bwrap sandbox) and will hang forever."
  log "       Fix: set securityContext.privileged=true in the Deployment"
  log "       and recreate the pod."
  log "       Check: cat /proc/sys/user/max_user_namespaces"
  log "              unshare -U /bin/true"
  return 1
}

start_steam() {
  # Start the Steam client in the background so CS2's IPC pipe peer exists.
  # Silent / no UI. STEAM_USERNAME + STEAM_PASSWORD env vars required; the
  # account MUST have Steam Guard disabled for this to be fully non-interactive.
  if pgrep -x steam >/dev/null 2>&1; then
    log "steam already running"
    return 0
  fi
  check_user_namespaces || return 1
  if [ -z "${STEAM_USERNAME:-}" ] || [ -z "${STEAM_PASSWORD:-}" ]; then
    log "WARN: STEAM_USERNAME / STEAM_PASSWORD not set — CS2 will hit 'Steam not running'"
    return 0
  fi
  local steam_bin
  steam_bin=$(find_steam_bin) || {
    log "WARN: steam binary not installed in image — install steam-installer in Dockerfile"
    return 1
  }

  log "launching $steam_bin -silent -login $STEAM_USERNAME (via dbus-launch)"
  log "  — steam output streams live below, also written to /tmp/steam.log"
  # Stream steam's output to this process's stderr (visible to the user)
  # AND to /tmp/steam.log. `stdbuf -oL` forces line-buffering so we see
  # progress in real time instead of chunked.
  # Prefix with "  [steam] " so it's visually separate from our own logs.
  (
    stdbuf -oL -eL dbus-launch --exit-with-session \
      "$steam_bin" -silent -login "$STEAM_USERNAME" "$STEAM_PASSWORD" 2>&1 \
      | stdbuf -oL tee /tmp/steam.log \
      | sed -u 's/^/  [steam] /' >&2
  ) &

  # Auto-dismiss any first-run dialog that might block startup.
  (
    while true; do
      for id in $(xdotool search --name 'Steam' 2>/dev/null) \
                $(xdotool search --name 'Setup' 2>/dev/null) \
                $(xdotool search --name 'Question' 2>/dev/null) \
                $(pgrep -x zenity 2>/dev/null | xargs -I{} xdotool search --pid {} 2>/dev/null); do
        xdotool windowactivate --sync "$id" key --clearmodifiers Return 2>/dev/null || true
      done
      sleep 2
    done
  ) &
  local dismisser_pid=$!

  local ok=0
  for i in $(seq 1 180); do
    if ls /tmp/steam_pipe_* >/dev/null 2>&1 || [ -p "$HOME/.steam/steam.pipe" ]; then
      log "steam IPC pipe is up after ${i}s"
      ok=1
      break
    fi
    # Heartbeat every 10s so the user knows we're alive.
    if [ $(( i % 10 )) -eq 0 ]; then
      log "  (still waiting for steam IPC pipe — ${i}s elapsed)"
    fi
    sleep 1
  done
  kill "$dismisser_pid" 2>/dev/null || true
  if [ "$ok" = "1" ]; then return 0; fi

  log "ERROR: steam IPC pipe never appeared after 180s"
  log "  check /root/.steam/steam/logs/console-linux.txt for the real Steam log:"
  if [ -f /root/.steam/steam/logs/console-linux.txt ]; then
    tail -n 40 /root/.steam/steam/logs/console-linux.txt | sed 's/^/    /' >&2 || true
  fi
  return 1
}

cleanup() {
  log "Shutting down"
  if [ -f /tmp/xorg.pid ]; then
    kill "$(cat /tmp/xorg.pid)" 2>/dev/null || true
  fi
  pkill -TERM -f cs2 2>/dev/null || true
  pkill -TERM -f gst-launch 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log "MODE=$MODE (SCRIPT_DIR=$SCRIPT_DIR)"
persist_steam_state
case "$MODE" in
  live)
    start_xorg
    install_cs2
    ensure_steamclient
    start_steam
    exec "$SCRIPT_DIR/live.sh"
    ;;
  render)
    start_xorg
    install_cs2
    ensure_steamclient
    start_steam
    exec "$SCRIPT_DIR/render.sh"
    ;;
  install)
    install_cs2
    ensure_steamclient
    ;;
  idle|*)
    start_xorg || log "continuing without Xorg (idle debug)"
    install_cs2 || log "continuing without CS2 install (idle debug)"
    ensure_steamclient || log "continuing without steamclient.so (idle debug)"
    start_steam || log "continuing without steam (idle debug)"
    log "Idle mode — sleeping. Set MODE=live or MODE=render, or shell in to debug."
    tail -f /dev/null
    ;;
esac
