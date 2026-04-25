#!/usr/bin/env bash
# PulseAudio user-mode daemon for capturing CS2's audio.

start_pulseaudio() {
  if pgrep -x pulseaudio >/dev/null 2>&1; then
    log "pulseaudio already running"
    return 0
  fi
  if ! command -v pulseaudio >/dev/null 2>&1; then
    log "WARN: pulseaudio not installed — capture pipeline will be video-only"
    return 0
  fi
  # --exit-idle-time=-1 keeps the daemon alive even when no clients are
  # connected (CS2 connects/disconnects the audio sink as it transitions
  # screens). --disable-shm avoids needing /dev/shm permissions.
  pulseaudio --start --exit-idle-time=-1 --disable-shm=true >/tmp/pulseaudio.log 2>&1 || {
    log "WARN: pulseaudio failed to start — see /tmp/pulseaudio.log"
    return 0
  }
  # Create a null sink so gst's pulsesrc has a valid monitor source even
  # without a real output device.
  pactl load-module module-null-sink sink_name=cs2 sink_properties=device.description=cs2 \
    >/dev/null 2>&1 || true
  pactl set-default-sink cs2 >/dev/null 2>&1 || true
  log "pulseaudio started (default sink: cs2, monitor: cs2.monitor)"
}
