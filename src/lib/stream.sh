# shellcheck shell=bash
# GStreamer SRT capture. Tagged by stream-id so we can find/kill specific streams.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

stream_pid() {
  local stream_id="$1"
  pgrep -f "publish:${stream_id}\b" | head -1
}

stream_running() {
  [ -n "$(stream_pid "$1")" ]
}

# start_capture <stream-id> [fps] [video-kbps] [show-pointer] [audio]
#   audio: 1 to include PulseAudio leg (default), 0 video-only
start_capture() {
  local stream_id="${1:?stream-id required}"
  local fps="${2:-30}"
  local kbps="${3:-4000}"
  local pointer="${4:-true}"
  local audio="${5:-${CAPTURE_AUDIO:-1}}"
  local gop=$(( fps * 2 ))
  local url="${MEDIAMTX_SRT_BASE}?streamid=publish:${stream_id}"
  local pulse_sink="${PULSE_SINK_NAME:-cs2}"
  local gst_tag="gst-${stream_id:0:8}"

  # Output dims: scale capture to LIVE_OUTPUT_DIMS (default 1920x1080).
  # CS2 may render at 1440p natively, but the live HLS stream + HUD
  # overlay CSS + viewer expectations all key off 1080p — and scaling
  # 1440p → 1080p at capture time gives a supersampled 1080p that's
  # crisper than rendering CS2 natively at 1080p.
  local live_out="${LIVE_OUTPUT_DIMS:-1920x1080}"
  local out_w="${live_out%x*}"
  local out_h="${live_out#*x}"
  [ -z "$out_w" ] && out_w=1920
  [ -z "$out_h" ] && out_h=1080

  if stream_running "$stream_id"; then
    return 0
  fi

  log "starting capture '${stream_id}' (${out_w}x${out_h}@${fps}fps kbps=$kbps audio=$audio) -> $url"

  # LIVE_VIDEO_CODEC=h265|h264. Default h264 — falls back to h264 if no NVENC HEVC.
  # Note: HEVC-over-WebRTC is Safari 17+ only; non-HEVC browsers fall back to HLS.
  local codec="${LIVE_VIDEO_CODEC:-h264}"
  local enc="" parse=""
  case "$codec" in
    h265|hevc)
      if enc=$(pick_h265_pipeline "$gop" "$kbps" live); then
        parse="h265parse config-interval=1"
      else
        warn "LIVE_VIDEO_CODEC=$codec but no NVENC HEVC encoder available — falling back to h264"
        codec="h264"
      fi
      ;;
    h264) : ;;
    *)
      warn "LIVE_VIDEO_CODEC=$codec unrecognized — using h264"
      codec="h264"
      ;;
  esac
  if [ "$codec" = "h264" ]; then
    enc=$(pick_h264_pipeline "$gop" "$kbps" live)
    parse="h264parse config-interval=1"
  fi
  log "  codec: $codec"

  # Scale + colorspace convert. Runs on the GPU (cudaconvertscale) when the
  # encoder is CUDA-based, off-loading it from the CPU that cs2 needs.
  local convert
  convert=$(pick_scale_convert "$out_w" "$out_h" "$fps" "$codec")
  _assert_cuda_chain "$convert" "$enc"

  # Persist args so restart_capture can re-invoke us identically.
  local args_dir="${LOG_DIR:-/tmp/game-streamer}"
  mkdir -p "$args_dir"
  printf '%s\n%s\n%s\n%s\n%s\n' \
    "$stream_id" "$fps" "$kbps" "$pointer" "$audio" \
    > "${args_dir}/capture-${stream_id}.args"

  # Resolve the audio source up front (both capture paths use it). Pin to our
  # named null sink's .monitor — pactl's default can drift to hud-manager's Pulse
  # client / silence.
  local pulse_source=""
  if [ "$audio" = 1 ]; then
    pulse_source="${pulse_sink}.monitor"
    if ! pactl list short sources 2>/dev/null | awk '{print $2}' | grep -qx "$pulse_source"; then
      warn "  ${pulse_source} not present — falling back to default source"
      if command -v get_default_source >/dev/null 2>&1; then
        pulse_source=$(get_default_source)
      else
        pulse_source=$(pactl info 2>/dev/null | awk -F': ' '/^Default Source/{print $2}')
      fi
      [ -n "$pulse_source" ] || pulse_source="${pulse_sink}.monitor"
    fi
  fi

  # COMPOSITE (cs2 present-hook + HUD overlay): capture cs2's swapchain via the
  # vkcapture consumer (no X-server contention) and overlay the JTs HUD in gst.
  # Used for live + demo when vkcapture + cs2 + the HUD window are present; any
  # miss falls back to the plain ximagesrc grab below (HUD via picom).
  # HUD grab rate: cs2 renders via the present-hook (not X), so this HUD ximagesrc
  # is the only X-server capture load. 30fps is smooth; tune via HUD_CAPTURE_FPS.
  local hud_xid="" used_composite=0 hud_fps="${HUD_CAPTURE_FPS:-30}"
  # HUD show/hide control file (composite only): the consumer polls it to alpha
  # the HUD pad; its presence tells the spec-server we're compositing. Clear any
  # stale copy so a non-composite path doesn't look composite.
  local hud_ctl="${LOG_DIR:-/tmp/game-streamer}/hud-visible"
  rm -f "$hud_ctl"
  if vkcapture_available \
     && pgrep -f '/linuxsteamrt64/cs2' >/dev/null 2>&1 \
     && command -v find_hud_overlay_window >/dev/null 2>&1; then
    hud_xid=$(find_hud_overlay_window 2>/dev/null || true)
  fi
  if [ -n "$hud_xid" ]; then
    log "  composite: cs2 present-hook + HUD overlay (xid=$hud_xid, hud=${hud_fps}fps)"
    # sink_0 = cs2 (base), sink_1 = HUD on top. The HUD ximagesrc MUST carry alpha
    # (BGRA) or it paints opaque over cs2.
    local cs2_src hud_src outchain
    if _gpu_compositor_ok "$codec"; then
      # GPU HUD blend: upload both legs to CUDA and let cudacompositor alpha-blend
      # on the GPU, then cudaconvertscale -> nvenc, all GPU-resident. Keeps the
      # 1080p60 blend off the 2 capture CPU cores (the software compositor's cost).
      # Opt-in (GS_GPU_COMPOSITOR=1); dies-on-spawn falls back to ximagesrc below.
      log "  composite: GPU HUD blend (cudacompositor) — alpha-blend off the capture CPU"
      cs2_src="appsrc name=vksrc ! queue ! videorate ! video/x-raw,framerate=$fps/1 ! cudaupload ! comp.sink_0"
      hud_src="ximagesrc xid=$hud_xid use-damage=0 show-pointer=false ! video/x-raw,framerate=$hud_fps/1 ! videoconvert ! video/x-raw,format=BGRA ! cudaupload ! queue leaky=downstream max-size-buffers=2 ! comp.sink_1"
      outchain="cudacompositor name=comp background=black ! cudaconvertscale ! video/x-raw(memory:CUDAMemory),format=NV12,width=$out_w,height=$out_h,framerate=$fps/1 ! $enc ! $parse"
    else
      # Software compositor (default): CPU alpha-blend on the capture cores.
      cs2_src="appsrc name=vksrc ! queue ! videorate ! video/x-raw,framerate=$fps/1 ! comp.sink_0"
      # leaky=downstream: a slow/blocked HUD grab drops its own frames instead of
      # back-pressuring the compositor (which would stall the cs2 leg too).
      hud_src="ximagesrc xid=$hud_xid use-damage=0 show-pointer=false ! video/x-raw,framerate=$hud_fps/1 ! videoconvert ! video/x-raw,format=BGRA ! queue leaky=downstream max-size-buffers=2 ! comp.sink_1"
      # queue after the compositor = a thread boundary so the software blend and the
      # upload/encode run on separate cores (else they serialize on one). Bounded by
      # buffer count — raw frames are big, so the default byte cap would throttle.
      outchain="compositor name=comp background=black ! queue max-size-buffers=8 max-size-bytes=0 max-size-time=0 ! $convert ! $enc ! $parse"
    fi
    local pipeline
    if [ "$audio" = 1 ]; then
      pipeline="$outchain ! queue ! mux. \
$cs2_src \
$hud_src \
pulsesrc device=$pulse_source buffer-time=400000 provide-clock=false ! audio/x-raw,rate=48000,channels=2 ! audioconvert ! audioresample ! opusenc bitrate=128000 ! opusparse ! queue ! mux. \
mpegtsmux name=mux alignment=7 ! srtsink uri=$url latency=200"
    else
      pipeline="$outchain ! mpegtsmux alignment=7 ! srtsink uri=$url latency=200 \
$cs2_src \
$hud_src"
    fi
    export VKCAP_FPS="$fps"
    # Zero-copy is clip-only: the software `compositor` here blends in system
    # memory and can't consume a device-local dmabuf. Force it off so a global
    # VKCAP_ZEROCOPY=1 can't push this path into the ximagesrc fallback.
    export VKCAP_ZEROCOPY=0
    # Seed visible=1; consumer reads VKCAP_HUD_CTL and polls it for show/hide.
    printf '1\n' > "$hud_ctl"
    export VKCAP_HUD_CTL="$hud_ctl"
    # Pin the capture pipeline to dedicated high cores so its gst threads don't
    # pile (wake-affinity) onto a core cs2 is using and peg it. cs2 is pinned to
    # the complementary cores at launch (cs2_cpu_pin), so the split is real — they
    # never share a core. CAPTURE_CPUS overrides the list (empty = no pin);
    # CAPTURE_CORES sets the count (2 is the floor — capture needs ~1.7 cores).
    local capture_pin=()
    compute_cpu_split
    if [ -n "${GS_CAPTURE_CPUS:-}" ] && command -v taskset >/dev/null 2>&1; then
      capture_pin=(taskset -c "$GS_CAPTURE_CPUS")
      log "  capture pinned to cores $GS_CAPTURE_CPUS (cs2 confined to ${GS_CS2_CPUS:-all})"
    fi
    spawn_logged "$gst_tag" "${capture_pin[@]}" vkcapture-consumer "$pipeline"
    sleep 1
    if kill -0 "$SPAWNED_PID" 2>/dev/null; then
      used_composite=1
    else
      warn "composite consumer died on spawn — falling back to ximagesrc"
      rm -f "$hud_ctl"
      unset VKCAP_HUD_CTL
    fi
  fi

  # ximagesrc fallback — grabs the composited X display (cs2 + HUD via picom). Used
  # when the composite is unavailable (no vkcapture / no cs2 / no HUD window, e.g.
  # the DEBUG_STREAM boot watch) or its consumer died. leaky=downstream decouples
  # the grab from convert+NVENC so a downstream hitch can't back-pressure the grab.
  if [ "$used_composite" = 0 ]; then
    if [ "$audio" = 1 ]; then
      # Opus: mediamtx forwards straight to WebRTC without per-viewer transcode.
      spawn_logged "$gst_tag" gst-launch-1.0 -e \
        ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer="$pointer" \
          ! video/x-raw,framerate="$fps"/1 \
          ! queue leaky=downstream max-size-buffers=3 max-size-bytes=0 max-size-time=0 \
          ! $convert \
          ! $enc \
          ! $parse \
          ! queue ! mux. \
        pulsesrc device="$pulse_source" buffer-time=400000 provide-clock=false \
          ! audio/x-raw,rate=48000,channels=2 \
          ! audioconvert \
          ! audioresample \
          ! opusenc bitrate=128000 \
          ! opusparse \
          ! queue ! mux. \
        mpegtsmux name=mux alignment=7 \
          ! srtsink uri="$url" latency=200
    else
      spawn_logged "$gst_tag" gst-launch-1.0 -e \
        ximagesrc display-name="$DISPLAY" use-damage=0 show-pointer="$pointer" \
          ! video/x-raw,framerate="$fps"/1 \
          ! queue leaky=downstream max-size-buffers=3 max-size-bytes=0 max-size-time=0 \
          ! $convert \
          ! $enc \
          ! $parse \
          ! mpegtsmux alignment=7 \
          ! srtsink uri="$url" latency=200
    fi
  fi

  # Liveness check — must survive pulse / NVENC init / srt handshake.
  local pid=$SPAWNED_PID
  local i
  for i in 1 2 3; do
    if ! kill -0 "$pid" 2>/dev/null; then
      warn "capture '${stream_id}' died after ${i}s"
      return 1
    fi
    sleep 1
  done

  # Live perf sampler: every GS_LIVE_DIAG_INTERVAL s (default 15) while the stream
  # runs, log GPU util/clock + cs2 CPU% + the CAPTURE pipeline's CPU%. This is the
  # one signal we lacked for live: if capcpu pegs ~its pin (200% on 2 cores) the
  # capture is CPU-bound — almost always the SOFTWARE compositor (composite path) —
  # and GPU compositing is the fix; if cs2cpu/gpu dip with capcpu low it's cs2-side.
  # Slow cadence so a multi-hour stream doesn't spam; GS_LIVE_DIAG=0 mutes. Detaches
  # and self-exits when the capture pid dies.
  if [ "${GS_LIVE_DIAG:-1}" = "1" ] && command -v nvidia-smi >/dev/null 2>&1; then
    (
      cap_pid="$pid" comp="$used_composite"
      cs2_pid=$(pgrep -f '/linuxsteamrt64/cs2' | head -1)
      hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
      jif() { awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null; }
      interval="${GS_LIVE_DIAG_INTERVAL:-15}"
      pcs2=$(jif "$cs2_pid"); pcap=$(jif "$cap_pid"); pms=$(date +%s%3N 2>/dev/null || echo 0)
      while kill -0 "$cap_pid" 2>/dev/null; do
        sleep "$interval"
        kill -0 "$cap_pid" 2>/dev/null || break
        now_ms=$(date +%s%3N 2>/dev/null || echo 0); dt=$(( now_ms - pms )); [ "$dt" -le 0 ] && dt=$((interval * 1000))
        g=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,clocks.gr,temperature.gpu \
              --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        ccs2=$(jif "$cs2_pid"); ccap=$(jif "$cap_pid")
        cs2cpu=$(awk -v a="${pcs2:-}" -v b="${ccs2:-}" -v dt="$dt" -v hz="$hz" 'BEGIN{if(a==""||b==""){print "?"}else printf "%.0f",(b-a)*1000.0/hz/dt*100}')
        capcpu=$(awk -v a="${pcap:-}" -v b="${ccap:-}" -v dt="$dt" -v hz="$hz" 'BEGIN{if(a==""||b==""){print "?"}else printf "%.0f",(b-a)*1000.0/hz/dt*100}')
        log "  LIVE-DIAG ${stream_id:0:8}: gpu(util,vramMiB,clkMHz,tempC)=${g} | cs2cpu=${cs2cpu}% capcpu=${capcpu}% (composite=${comp})"
        pcs2=$ccs2; pcap=$ccap; pms=$now_ms
      done
    ) &
  fi

  # Log the watchable HLS URL (grep "WATCH") for the early/boot phase.
  local dom="${GAME_STREAM_DOMAIN:-hls.5stack.gg}"
  dom="${dom%/}"
  case "$dom" in
    http://*|https://*) ;;
    *) dom="https://$dom" ;;
  esac
  log "WATCH (HLS): ${dom}/${stream_id}/index.m3u8"

  return 0
}

restart_capture() {
  local stream_id="${1:?stream-id required}"
  local args_file="${LOG_DIR:-/tmp/game-streamer}/capture-${stream_id}.args"
  if [ ! -f "$args_file" ]; then
    warn "restart_capture: no saved args for '${stream_id}'"
    return 1
  fi
  local sid fps kbps pointer audio
  { read -r sid; read -r fps; read -r kbps; read -r pointer; read -r audio; } < "$args_file"

  stop_capture "$stream_id"
  # Let mediamtx clear the stale publisher before reconnecting.
  sleep 1
  start_capture "$sid" "$fps" "$kbps" "$pointer" "$audio"
}

stop_capture() {
  local stream_id="${1:?stream-id required}"
  local pid
  pid=$(stream_pid "$stream_id") || true
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  fi
}
