# shellcheck shell=bash
# PulseAudio for headless capture. Pattern:
#   * Start pulseaudio --user mode (no system D-Bus needed)
#   * Create a null sink named $PULSE_SINK_NAME (default 'cs2')
#   * Make it the default sink so cs2 routes audio there
#   * GStreamer captures from <sink>.monitor

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${PULSE_SINK_NAME:=cs2}"
: "${PULSE_RUNTIME_DIR:=$XDG_RUNTIME_DIR/pulse}"
# Loopback TCP listener (loaded by start_pulseaudio after the daemon is
# up). PULSE_SERVER itself is exported AFTER the load — exporting it
# before `pulseaudio --start` makes pulse think a remote server is
# already configured and it refuses to autospawn:
#   "User-configured server at tcp:..., refusing to start/autospawn."
: "${PULSE_TCP_PORT:=4713}"
: "${PULSE_TCP_HOST:=127.0.0.1}"
export PULSE_SINK_NAME PULSE_RUNTIME_DIR PULSE_TCP_PORT PULSE_TCP_HOST
mkdir -p "$PULSE_RUNTIME_DIR"
chmod 700 "$PULSE_RUNTIME_DIR"

pulseaudio_running() {
  pgrep -x pulseaudio >/dev/null 2>&1 && pactl info >/dev/null 2>&1
}

# Bring up PulseAudio in user mode and the cs2 null sink. Idempotent.
start_pulseaudio() {
  # Crucial: PULSE_SERVER must NOT be set during `pulseaudio --start`
  # or any client probe before the daemon is up — pulse interprets it
  # as "a server already exists, don't autospawn", and refuses to
  # start. We unset for the duration of bring-up + module-loads, then
  # export it at the end so callers (cs2, gst, pactl in fresh shells)
  # can resolve via the TCP socket we just loaded.
  local prior_pulse_server="${PULSE_SERVER:-}"
  unset PULSE_SERVER

  if pulseaudio_running; then
    log "pulseaudio already up"
  else
    log "starting pulseaudio"
    # --start daemonizes if not already running. --exit-idle-time=-1
    # keeps it alive even when no clients connect. Pulse's own daemon
    # forks; spawn_logged just tags the brief startup output.
    spawn_logged pulseaudio pulseaudio --start --exit-idle-time=-1 \
      --log-target=stderr
    local i
    for i in $(seq 1 20); do
      pactl info >/dev/null 2>&1 && break
      sleep 0.5
    done
    pactl info >/dev/null 2>&1 \
      || die "pulseaudio failed to start (see [pulseaudio] log lines above)"
    log "  pulseaudio up"
  fi

  # Silence the linter — we deliberately drop the prior value if any.
  : "${prior_pulse_server:=}"

  # Null sink for cs2's output. .monitor source is what gstreamer reads.
  # NOTE: don't pass sink_properties with embedded spaces — PulseAudio's
  # module-arg parser splits on whitespace before quote-stripping, so
  # `sink_properties=device.description='cs2 capture'` fails with
  # "Failed to parse module arguments" and the sink never loads. The
  # default description is fine; it's cosmetic.
  if pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -qx "$PULSE_SINK_NAME"; then
    log "  null sink '$PULSE_SINK_NAME' exists"
  else
    log "  creating null sink '$PULSE_SINK_NAME'"
    if ! pactl load-module module-null-sink sink_name="$PULSE_SINK_NAME" >/dev/null; then
      warn "module-null-sink load failed — apps will route to auto_null (see [pulseaudio] log lines above)"
    fi
  fi
  pactl set-default-sink "$PULSE_SINK_NAME" 2>/dev/null || true
  log "  default sink:   $(pactl info 2>/dev/null | awk -F': ' '/^Default Sink/{print $2}')"
  log "  default source: $(pactl info 2>/dev/null | awk -F': ' '/^Default Source/{print $2}')"

  # TCP listener so PULSE_SERVER=tcp:127.0.0.1:4713 works even when
  # XDG_RUNTIME_DIR is missing in the consumer's env. auth-anonymous=1
  # is safe here because pulse only binds to loopback — the container
  # has no other listeners on 4713 and there's no port-forward of it.
  if pactl list short modules 2>/dev/null | awk '{print $2}' | grep -qx module-native-protocol-tcp; then
    log "  pulse tcp listener already loaded"
  else
    log "  loading pulse tcp listener on ${PULSE_TCP_HOST}:${PULSE_TCP_PORT}"
    if ! pactl load-module module-native-protocol-tcp \
           "listen=${PULSE_TCP_HOST}" "port=${PULSE_TCP_PORT}" \
           auth-anonymous=1 >/dev/null; then
      warn "module-native-protocol-tcp load failed — cs2 may not find pulse via PULSE_SERVER (see [pulseaudio] log lines above)"
    fi
  fi
  # Now safe to export — daemon is up and listening on TCP. Do this
  # AFTER everything above so the bring-up path itself never sees
  # PULSE_SERVER set (see comment in start_pulseaudio's prologue).
  export PULSE_SERVER="tcp:${PULSE_TCP_HOST}:${PULSE_TCP_PORT}"
  log "  PULSE_SERVER=$PULSE_SERVER (advertise to cs2 + diagnostics)"
}

# Echoes the name of the default PulseAudio source — typically the
# default sink's `.monitor`. Used as the gstreamer pulsesrc device so
# capture works regardless of which sink Pulse ended up using
# (cs2.monitor when our null sink loaded, auto_null.monitor when not).
get_default_source() {
  pactl info 2>/dev/null | awk -F': ' '/^Default Source/{print $2}'
}

stop_pulseaudio() {
  pulseaudio --kill 2>/dev/null || true
  pkill -x pulseaudio 2>/dev/null || true
}

# Diagnostic: prints what pulse sees + plays a 2s 440Hz tone into the
# cs2 sink so the next iteration of the match capture stream has
# audible audio (you should hear the tone in the HLS player).
audio_state() {
  log "PULSE STATE"
  log "  default sink: $(pactl info 2>/dev/null | awk -F': ' '/Default Sink/{print $2}')"
  log "  default source: $(pactl info 2>/dev/null | awk -F': ' '/Default Source/{print $2}')"
  log "  sinks:"
  pactl list short sinks   2>/dev/null | sed 's/^/    /' || log "    (none)"
  log "  sources (monitors):"
  pactl list short sources 2>/dev/null | sed 's/^/    /' || log "    (none)"
  log "  sink-inputs (apps playing audio):"
  pactl list short sink-inputs 2>/dev/null | sed 's/^/    /' || log "    (none)"
  log "  source-outputs (apps recording, e.g. our gst pulsesrc):"
  pactl list short source-outputs 2>/dev/null | sed 's/^/    /' || log "    (none)"
}

audio_test_tone() {
  local sink="${PULSE_SINK_NAME:-cs2}"
  log "playing 2s 440Hz tone into sink '$sink' (you should hear it on the HLS stream)"
  PULSE_SINK="$sink" \
    gst-launch-1.0 -e \
      audiotestsrc num-buffers=200 wave=sine freq=440 \
      ! audio/x-raw,rate=48000,channels=2 \
      ! pulsesink device="$sink" \
      >/dev/null 2>&1 &
  log "  tone pid=$!"
}
