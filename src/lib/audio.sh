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
export PULSE_SINK_NAME PULSE_RUNTIME_DIR
mkdir -p "$PULSE_RUNTIME_DIR"
chmod 700 "$PULSE_RUNTIME_DIR"

pulseaudio_running() {
  pgrep -x pulseaudio >/dev/null 2>&1 && pactl info >/dev/null 2>&1
}

# Bring up PulseAudio in user mode and the cs2 null sink. Idempotent.
start_pulseaudio() {
  if pulseaudio_running; then
    log "pulseaudio already up"
  else
    log "starting pulseaudio (log: $LOG_DIR/pulseaudio.log)"
    # --start daemonizes if not already running. --exit-idle-time=-1
    # keeps it alive even when no clients connect.
    nohup pulseaudio --start --exit-idle-time=-1 --log-target=newfile:"$LOG_DIR/pulseaudio.log" \
      >/dev/null 2>&1 &
    local i
    for i in $(seq 1 20); do
      pactl info >/dev/null 2>&1 && break
      sleep 0.5
    done
    pactl info >/dev/null 2>&1 \
      || { dump_log "$LOG_DIR/pulseaudio.log"; die "pulseaudio failed to start"; }
    log "  pulseaudio up"
  fi

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
      warn "module-null-sink load failed — apps will route to auto_null"
      dump_log "$LOG_DIR/pulseaudio.log" 20
    fi
  fi
  pactl set-default-sink "$PULSE_SINK_NAME" 2>/dev/null || true
  log "  default sink:   $(pactl info 2>/dev/null | awk -F': ' '/^Default Sink/{print $2}')"
  log "  default source: $(pactl info 2>/dev/null | awk -F': ' '/^Default Source/{print $2}')"
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
