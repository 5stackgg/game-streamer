#!/usr/bin/env bash
# game-streamer — production entry point. Subcommand list + required
# env are documented in usage() below.

set -uo pipefail
SCRIPT_TAG=game-streamer

# shellcheck disable=SC1091
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/xorg.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/stream.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/audio.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/steam.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/openhud.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/spec-server.sh"

load_env

# Top-level flags (must come before the subcommand).
#   --debug : publish an on-screen capture stream to publish:$DEBUG_STREAM_ID
#             (default 'debug') for the duration of the run. Watch at
#             https://${GAME_STREAM_DOMAIN}/${DEBUG_STREAM_ID}/.
DEBUG_CAPTURE="${DEBUG_CAPTURE:-0}"
: "${DEBUG_STREAM_ID:=debug}"
while [ $# -gt 0 ]; do
  case "$1" in
    --debug)         DEBUG_CAPTURE=1; shift ;;
    --debug-id)      DEBUG_STREAM_ID="$2"; DEBUG_CAPTURE=1; shift 2 ;;
    --debug-id=*)    DEBUG_STREAM_ID="${1#*=}"; DEBUG_CAPTURE=1; shift ;;
    --trace|-x)      GS_TRACE=1; shift ;;
    --)              shift; break ;;
    *)               break ;;
  esac
done
export DEBUG_CAPTURE DEBUG_STREAM_ID GS_TRACE
[ "${GS_TRACE:-0}" = "1" ] && set -x

usage() {
  cat <<EOF
usage: $(basename "$0") [--debug] <command> [args]

flows:
  setup-steam              flow 1: register library + start Steam (UI visible)
  run-live                 flow 2: launch CS2 + start match capture
                           (requires flow 1 to have completed login)
  run-demo                 flow 2 variant: download \$DEMO_URL and play
                           it back via +playdemo + start capture
  live                     run flow 1 then flow 2 end-to-end. Setup waits
                           until the main Steam UI window is rendered
                           before launching CS2.
  demo                     run flow 1 then flow 2 (demo variant) end-to-end.
  batch-highlights         demo variant — render every job in
                           \$CLIP_BATCH_JOBS sequentially against the
                           same cs2 instance, then exit. Spawned by
                           the api on match metadata-parsed.

global flags:
  --debug                  publish on-screen capture to publish:debug
                           (watch at https://${GAME_STREAM_DOMAIN}/debug/)
  --debug-id <id>          override the debug stream id (implies --debug)
  --trace, -x              set -x on every script (very loud, for debug)

debug stream (ad-hoc):
  debug-stream start [id]  start screen-capture stream (default id: 'debug')
  debug-stream stop  [id]
  debug-stream url   [id]  print HLS playback URL

control:
  status                   show xorg / steam / streams / cs2 / x windows
  windows                  print only the open X windows (cheap to poll)
  dismiss                  activate Steam window + send Space — dismisses
                           CEF modal dialogs (cloud-out-of-date "Play anyway",
                           shader pre-cache "Skip") via the default-focused
                           button
  hide-steam               minimize the Steam main UI + Friends List
                           (called automatically by run-live once cs2 is up,
                           keeps stray clicks off Steam UI buttons)
  cs2-console              open CS2's dev console (sends backtick to cs2)
  cs2-connect              open dev console and connect to the running
                           match. Picks the first available mode in
                           priority order:
                             1. \$PLAYCAST_URL                       → playcast
                             2. \$CONNECT_TV_ADDR/_PASSWORD          → TV port
                             3. \$CONNECT_ADDR/\$CONNECT_PASSWORD    → game port
                           (values from pod env or src/.env)
  cs2-playdemo [path]      open dev console and type:
                             playdemo <path>
                           (defaults to \$DEMO_FILE or /tmp/game-streamer/demo.dem)
  spec-auto on|off         toggle CS2 auto-director at runtime:
                             on  → spec_autodirector 1; spec_mode 5 (director cam)
                             off → spec_autodirector 0 (manual control)
  spec-server start|stop|status|log
                           manage the cs2 spectator-control HTTP daemon
                           on :\$SPEC_SERVER_PORT (default 1350).
                           Routes: POST /spec/{click,jump,player,autodirector}
  audio-state              print PulseAudio state: default sink, sinks,
                           monitor sources, sink-inputs (apps playing),
                           source-outputs (gst pulsesrc capturing)
  audio-test               play a 2s 440Hz tone into the cs2 sink — should
                           be audible on the HLS stream if the audio leg
                           of the gst pipeline is working
  install-cs2              install/update CS2 via steamcmd into the
                           registered library (kills Steam, runs steamcmd,
                           leaves Steam off — re-run 'live' afterward).
                           Set CS2_FORCE_UPDATE=1 to force re-validate.
  steam-log                tail Steam's own on-disk logs (console-linux,
                           stderr, cef_log, webhelper-linux). Process
                           output (steam, xorg, openbox, openhud, gst)
                           lives in the k8s pod log: 'kubectl logs ...'.
  debug                    full diagnostic dump (env, processes, pipe,
                           steamclient, binaries, runtime, user-namespaces,
                           windows, crash dumps, manifest, cloud, disk).
  openhud-status           OpenHud process / server / picom / window state
  openhud-restart          stop + relaunch OpenHud + wait for server
  openhud-seed [match-id]  re-run the OpenHud DB seed from the 5stack API
                           (defaults to \$MATCH_ID)
  openhud-position         re-raise the HUD overlay window above cs2
  cloud-state              print Steam Cloud setting from disk (no edit)
  cloud-debug              verbose dump: file paths, mtimes, raw VDF
                           blocks (730 + Cloud + CloudEnabled), Steam
                           log lines mentioning cloud — use when the
                           dialog still appears despite disable-cloud
  disable-cloud            cycle Steam: kill -9 -> edit cloud=off -> relaunch
                           (use when 'Cloud Out of Date' dialog appears)
  stop-live                kill cs2 + match capture stream (keep Steam)
  stop-all                 kill cs2, capture, Steam, openbox, Xorg

env loaded from: $SRC_DIR/.env (if present)
state dir:       $LOG_DIR  (markers + json caches; logs stream to k8s)
EOF
}

cmd_status() {
  say "xorg"
  if xorg_running; then
    log "up on $DISPLAY"
  else
    log "not running"
  fi

  say "steam"
  if steam_pipe_up; then
    log "PIPE UP (pid $(cat "$HOME/.steam/steam.pid"))"
  else
    log "no pipe"
  fi
  if [ -L "$SDK64_LINK" ]; then
    log "sdk64/steamclient.so -> $(readlink -f "$SDK64_LINK")"
  fi

  say "cs2"
  local cs2_pid
  cs2_pid=$(pgrep -f '/linuxsteamrt64/cs2' | head -1)
  if [ -n "$cs2_pid" ]; then
    log "running (pid $cs2_pid)"
  else
    log "not running"
  fi

  say "capture streams"
  local found=0
  while IFS= read -r line; do
    log "  $line"
    found=1
  done < <(pgrep -af 'gst-launch.*publish:' || true)
  [ "$found" = 0 ] && log "  none"

  say "x windows"
  list_x_windows
}

cmd_debug_stream() {
  local sub="${1:-}"; shift || true
  local id="${1:-${DEBUG_STREAM_ID:-debug}}"
  case "$sub" in
    start)
      start_xorg
      start_capture "$id" 30 4000 true
      log "watch: https://${GAME_STREAM_DOMAIN}/${id}/"
      ;;
    stop)  stop_capture "$id" ;;
    url)   echo "https://${GAME_STREAM_DOMAIN}/${id}/" ;;
    *)     echo "usage: debug-stream start|stop|url [stream-id]" >&2; exit 2 ;;
  esac
}

cmd_stop_live() {
  pkill -9 -f '/linuxsteamrt64/cs2' 2>/dev/null || true
  if [ -n "${MATCH_ID:-}" ]; then
    stop_capture "$MATCH_ID"
  else
    log "MATCH_ID not set — skipping match capture stop"
  fi
}

cmd_stop_all() {
  cmd_stop_live
  stop_capture "${DEBUG_STREAM_ID:-debug}"
  stop_spec_server
  stop_openhud
  stop_picom
  kill_steam
  stop_pulseaudio
  stop_xorg
  log "all stopped"
}

cmd_steam_log() {
  # Process stdout/stderr (steam wrapper, xorg, openbox, openhud, gst,
  # spec-server) all stream to the k8s pod log live under their
  # [<tag>] prefixes — `kubectl logs` is the canonical view. The files
  # below are written by Steam itself and aren't in the container log,
  # so we tail them directly.
  local f
  for f in "$STEAM_HOME/logs/console-linux.txt" \
           "$STEAM_HOME/logs/stderr.txt" \
           "$STEAM_HOME/logs/cef_log.txt" \
           "$STEAM_HOME/logs/webhelper-linux.txt"; do
    if [ -f "$f" ]; then
      log "--- $f (last 60) ---"
      tail -60 "$f" | sed 's/^/    /'
    fi
  done
  log "(for our own process output run: kubectl logs -n 5stack <pod>)"
}

# Comprehensive single-command dump. Streams to stdout — k8s captures it.
cmd_debug() {
  print_full_debug
}

cmd_install_cs2() {
  require_env STEAM_USER STEAM_PASSWORD
  say "kill Steam (steamcmd + Steam clash on appmanifest writes)"
  kill_steam
  say "register library + install CS2 via steamcmd"
  register_library "$STEAM_LIBRARY"
  install_cs2_via_steamcmd
  log "done. Re-run 'src/game-streamer.sh live' to bring Steam back up + launch"
}

cmd_disable_cloud() {
  require_env STEAM_USER STEAM_PASSWORD
  say "kill Steam (-9 — no graceful shutdown so the file edit isn't clobbered)"
  kill_steam
  say "edit registry.vdf + config.vdf + localconfig.vdf + sharedconfig.vdf"
  disable_cloud_globally
  disable_cloud_in_config_vdf
  disable_cs2_cloud
  print_cloud_state
  say "relaunch Steam"
  start_steam
  wait_for_steam_pipe "${STEAM_PIPE_TIMEOUT:-300}"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  setup-steam)  exec "$FLOWS_DIR/setup-steam.sh" "$@" ;;
  run-live)     exec "$FLOWS_DIR/run-live.sh"    "$@" ;;
  run-demo)     exec "$FLOWS_DIR/run-demo.sh"    "$@" ;;
  # `up` is the legacy name — kept as an alias of `live` so older
  # pod manifests and any scripts pinned to the previous arg keep
  # working without coordinated redeploys.
  live | up)
    "$FLOWS_DIR/setup-steam.sh" "$@" || exit $?
    exec "$FLOWS_DIR/run-live.sh" "$@"
    ;;
  demo)
    mkdir -p /tmp/game-streamer
    # Kick the demo download off in parallel with setup-steam. setup
    # takes 60-90s; a typical demo is 100-300MB and downloads in
    # 5-30s — so by the time setup is done, the demo is usually
    # already on disk and run-demo's "downloading_demo" stage flips
    # to done immediately. Marker files (.dem on success / .failed on
    # error) let run-demo poll without owning the curl pid.
    if [ -n "${DEMO_URL:-}" ]; then
      DEMO_FILE_BG="${DEMO_FILE:-/tmp/game-streamer/demo.dem}"
      rm -f "$DEMO_FILE_BG" "$DEMO_FILE_BG.failed" "$DEMO_FILE_BG.partial"
      (
        # shellcheck disable=SC1091
        . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"
        # shellcheck disable=SC1091
        . "$LIB_DIR/status-reporter.sh"
        SCRIPT_TAG=demo-download
        # Report downloading_demo HERE — the parallel curl is the
        # actual download. Without this the only `downloading_demo`
        # report comes from run-demo.sh AFTER the file is already on
        # disk, gets coalesced into the next status by the 2s daemon
        # poll, and the web stepper marks the stage SKIPPED. Same
        # fix-pattern applies to workshop-bg below and to anywhere
        # else a backgrounded subshell is doing user-visible work.
        report_status status=downloading_demo
        if curl --fail --silent --show-error --location \
                --retry 5 --retry-delay 2 --retry-all-errors \
                --max-time "${DEMO_DOWNLOAD_TIMEOUT:-300}" \
                --output "$DEMO_FILE_BG.partial" \
                "$DEMO_URL"; then
          mv -f "$DEMO_FILE_BG.partial" "$DEMO_FILE_BG"
        else
          touch "$DEMO_FILE_BG.failed"
        fi
      ) > >(awk '{print "[demo-download] " $0; fflush()}' >&2) 2>&1 &
      echo $! > /tmp/game-streamer/demo-download.pid
    fi
    # Workshop map: parallel-ish — runs in the same steamcmd "lane"
    # as the cs2 install, which means it has to WAIT for the cs2
    # install to finish (or be already-installed). Two concurrent
    # steamcmd processes fight over ~/.steam state; if we ran them
    # truly in parallel the workshop download would race the cs2
    # install and silently drop, leaving cs2 to prompt "Subscribe?"
    # at +playdemo time.
    #
    # Lifecycle: poll for the cs2 appmanifest (written by stage 5 of
    # setup-steam.sh); once present, run download_workshop_map.
    # Marker files: <target>/*.vpk on success, /tmp/.../workshop-${id}.failed
    # on error. run-demo.sh waits for one of them in stage 3d.
    if [ -n "${WORKSHOP_ID:-}" ]; then
      WORKSHOP_TARGET="${STEAM_LIBRARY:-/mnt/game-streamer}/steamapps/workshop/content/730/${WORKSHOP_ID}"
      WORKSHOP_FAILED="/tmp/game-streamer/workshop-${WORKSHOP_ID}.failed"
      CS2_MANIFEST="${STEAM_LIBRARY:-/mnt/game-streamer}/steamapps/appmanifest_730.acf"
      rm -f "$WORKSHOP_FAILED"
      (
        # shellcheck disable=SC1091
        . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"
        # shellcheck disable=SC1091
        . "$LIB_DIR/steam.sh"
        # shellcheck disable=SC1091
        . "$LIB_DIR/status-reporter.sh"
        SCRIPT_TAG=workshop-bg
        # Wait for cs2 install (own steamcmd run) to finish before
        # starting our own. Caps at the same timeout used elsewhere
        # so a stuck cs2 install doesn't block forever.
        for _ in $(seq 1 600); do
          [ -f "$CS2_MANIFEST" ] && break
          sleep 2
        done
        if [ ! -f "$CS2_MANIFEST" ]; then
          warn "cs2 manifest never appeared — skipping workshop download"
          touch "$WORKSHOP_FAILED"
          exit 0
        fi
        # Same coalescing-fix as the demo-download branch above —
        # report the status from the actual worker so the web stepper
        # doesn't mark this stage SKIPPED when it really did run.
        report_status status=downloading_workshop_map "workshop_id=${WORKSHOP_ID}"
        if download_workshop_map "$WORKSHOP_ID"; then
          : # download_workshop_map already left the .vpk in place
        else
          touch "$WORKSHOP_FAILED"
        fi
      ) > >(awk '{print "[workshop-download] " $0; fflush()}' >&2) 2>&1 &
      echo $! > /tmp/game-streamer/workshop-download.pid
    fi
    "$FLOWS_DIR/setup-steam.sh" "$@" || exit $?
    exec "$FLOWS_DIR/run-demo.sh" "$@"
    ;;
  # Note: there's no `render-clip` top-level command. User-initiated
  # clip rendering runs INSIDE an existing demo-watch pod, driven by
  # the spec-server's /demo/render-clip route which spawns
  # lib/inline-clip-render.sh. See clips.service.ts on the api side.
  #
  # `batch-highlights` chains the demo flow (setup-steam → download
  # demo → run-demo.sh) with CLIP_BATCH_MODE=1 set, which tells
  # run-demo.sh to run process_batch_jobs() after setup instead of
  # holding the pod open. process_batch_jobs reads CLIP_BATCH_JOBS
  # (JSON array of {job_id, token, spec}) from env and invokes
  # inline-clip-render.sh for each, reusing the same cs2 instance
  # across renders.
  batch-highlights)
    export CLIP_BATCH_MODE=1
    mkdir -p /tmp/game-streamer
    if [ -n "${DEMO_URL:-}" ]; then
      DEMO_FILE_BG="${DEMO_FILE:-/tmp/game-streamer/demo.dem}"
      rm -f "$DEMO_FILE_BG" "$DEMO_FILE_BG.failed" "$DEMO_FILE_BG.partial"
      (
        # shellcheck disable=SC1091
        . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"
        SCRIPT_TAG=demo-download
        if curl --fail --silent --show-error --location \
                --retry 5 --retry-delay 2 --retry-all-errors \
                --max-time "${DEMO_DOWNLOAD_TIMEOUT:-300}" \
                --output "$DEMO_FILE_BG.partial" \
                "$DEMO_URL"; then
          mv -f "$DEMO_FILE_BG.partial" "$DEMO_FILE_BG"
        else
          touch "$DEMO_FILE_BG.failed"
        fi
      ) > >(awk '{print "[demo-download] " $0; fflush()}' >&2) 2>&1 &
      echo $! > /tmp/game-streamer/demo-download.pid
    fi
    "$FLOWS_DIR/setup-steam.sh" "$@" || exit $?
    exec "$FLOWS_DIR/run-demo.sh" "$@"
    ;;
  debug-stream) cmd_debug_stream "$@" ;;
  status|state)   cmd_status ;;
  windows)        list_x_windows ;;
  dismiss)         poke_steam_dialog ;;
  hide-steam)      minimize_steam_windows ;;
  cs2-console)     cs2_open_console ;;
  cs2-connect)
    load_env
    # Three connect modes — same fallback chain as run-live.sh:
    #   1. PLAYCAST_URL                            (api: usePlaycast)
    #   2. CONNECT_TV_ADDR + CONNECT_TV_PASSWORD   (api: server has TV port)
    #   3. CONNECT_ADDR + CONNECT_PASSWORD         (api: game-port fallback)
    if [ -n "${PLAYCAST_URL:-}" ]; then
      cs2_console_command "playcast \"$PLAYCAST_URL\""
    elif [ -n "${CONNECT_TV_ADDR:-}" ]; then
      cs2_console_connect "$CONNECT_TV_ADDR" "${CONNECT_TV_PASSWORD:-}"
    elif [ -n "${CONNECT_ADDR:-}" ]; then
      cs2_console_connect "$CONNECT_ADDR" "${CONNECT_PASSWORD:-}"
    else
      die "no connect target — set PLAYCAST_URL, or CONNECT_TV_ADDR+CONNECT_TV_PASSWORD, or CONNECT_ADDR+CONNECT_PASSWORD"
    fi
    ;;
  cs2-playdemo)
    # Manually trigger demo playback. Defaults to whatever
    # run-demo.sh wrote to disk; pass an explicit path to override.
    # Useful for debugging when +playdemo on the launch line silently
    # no-op'd: kubectl exec into the pod, run this, watch the debug
    # stream to confirm cs2 receives the command.
    DEMO_PATH="${1:-${DEMO_FILE:-/tmp/game-streamer/demo.dem}}"
    if [ ! -f "$DEMO_PATH" ]; then
      echo "demo file not found at $DEMO_PATH" >&2
      exit 2
    fi
    cs2_console_command "playdemo $DEMO_PATH"
    ;;
  spec-auto)
    case "${1:-}" in
      on)  cs2_console_command "spec_autodirector 1; spec_mode 5" ;;
      off) cs2_console_command "spec_autodirector 0" ;;
      *)   echo "usage: spec-auto on|off" >&2; exit 2 ;;
    esac
    ;;
  spec-server)
    case "${1:-}" in
      start)  start_spec_server ;;
      stop)   stop_spec_server ;;
      status) spec_server_status ;;
      *)      echo "usage: spec-server start|stop|status (logs: kubectl logs)" >&2; exit 2 ;;
    esac
    ;;
  audio-state)     audio_state ;;
  audio-test)      audio_test_tone ;;
  install-cs2)    cmd_install_cs2 ;;
  steam-log)      cmd_steam_log ;;
  debug)          cmd_debug "$@" ;;
  openhud-status)   openhud_status ;;
  openhud-restart)  stop_openhud; sleep 1; start_openhud; wait_for_openhud_server 60 ;;
  openhud-seed)     seed_openhud_db "${1:-${MATCH_ID:?MATCH_ID not set}}" ;;
  openhud-position) position_openhud_overlay ;;
  cloud-state)    print_cloud_state ;;
  cloud-debug)    print_cloud_debug ;;
  disable-cloud)  cmd_disable_cloud ;;
  stop-live)      cmd_stop_live ;;
  stop-all)       cmd_stop_all ;;
  -h|--help|help|"") usage ;;
  *) echo "unknown command: $cmd" >&2; usage >&2; exit 2 ;;
esac
