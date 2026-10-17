# shellcheck shell=bash
# Xorg + openbox bringup. Idempotent.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# A wedged X server (GTX 980 + nvidia 580 kernel-modeset hang) keeps its
# process alive but never answers, so a bare xdpyinfo blocks forever — every
# probe is `timeout`-guarded so a wedge reads as "not answering" in 5s instead
# of hanging the whole boot before a single log line is emitted.
xorg_running() {
  if [ "${GS_GPU_VENDOR:-}" = amd ] && [ "$(gs_display_tier)" = C ]; then
    _tier_c_running
    return $?
  fi
  pgrep -x Xorg >/dev/null 2>&1 && timeout 5 xdpyinfo -display "$DISPLAY" >/dev/null 2>&1
}

# Try to bind Xorg on :$n. Returns 0 if Xorg is up and answering, 1 if
# the display is owned (host desktop, foreign X, abstract-socket carcass)
# or Xorg otherwise failed. Never touches files belonging to a foreign X.
_try_start_xorg_on() {
  local n="$1"
  local disp=":$n"

  # Foreign X already answering → leave it alone, move on. timeout-guarded so a
  # wedged foreign server on this display can't hang the walk (see xorg_running).
  if timeout 5 xdpyinfo -display "$disp" >/dev/null 2>&1; then
    log "xorg: $disp already has a live X server — skipping"
    return 1
  fi
  # Lock file owned by a process visible to us → foreign X in our ns,
  # don't clobber. (Cross-namespace owners won't be visible — the bind
  # attempt below is the real backstop for that case.)
  if [ -e "/tmp/.X${n}-lock" ]; then
    local owner
    owner=$(awk '{print $1+0; exit}' "/tmp/.X${n}-lock" 2>/dev/null)
    if [ -n "$owner" ] && [ "$owner" -gt 0 ] && kill -0 "$owner" 2>/dev/null; then
      log "xorg: $disp lock owned by live PID $owner — skipping"
      return 1
    fi
    rm -f "/tmp/.X${n}-lock" 2>/dev/null || true
  fi
  # Only safe to remove the socket file once we've ruled out a live owner.
  [ -S "/tmp/.X11-unix/X${n}" ] && rm -f "/tmp/.X11-unix/X${n}" 2>/dev/null || true

  log "starting Xorg on $disp"
  # Xorg.wrap (setuid) refuses absolute paths for -config — must be
  # a bare filename in Xorg's search path.
  local cmd=(Xorg "$disp" -config "$XORG_CONFIG" -noreset
             -nolisten tcp -listen unix vt7)
  spawn_logged xorg "${cmd[@]}"
  local xpid=$SPAWNED_PID
  local i
  for i in $(seq 1 20); do
    # timeout-guarded: a fresh Xorg that wedges mid-modeset would otherwise
    # block this probe forever and the loop would never reach its kill below.
    timeout 5 xdpyinfo -display "$disp" >/dev/null 2>&1 && return 0
    if ! kill -0 "$xpid" 2>/dev/null; then
      # Two causes look identical from here: a foreign X in another ns holding
      # the display, or the GPU having no scanout at all ("no screens found").
      local why="foreign X in another ns"
      grep -qs 'no screens found' "/var/log/Xorg.${n}.log" && why="'no screens found' — display owned elsewhere, or this GPU has no scanout"
      log "xorg: $disp bind failed ($why)"
      return 1
    fi
    sleep 0.5
  done
  log "xorg: $disp never accepted clients within 10s — killing"
  kill "$xpid" 2>/dev/null || true
  for i in $(seq 1 10); do
    kill -0 "$xpid" 2>/dev/null || return 1
    sleep 0.5
  done
  kill -9 "$xpid" 2>/dev/null || true
  sleep 2
  # An Xorg that survives SIGKILL is stuck in the kernel (nvidia-modeset waiting
  # on the GPU). Every further Xorg blocks behind it, so walking on just stacks
  # more stuck servers onto the same GPU.
  if kill -0 "$xpid" 2>/dev/null; then
    # S3-D12: AMD gets its own text, without the nvidia-modeset advice of the die below.
    if [ "${GS_GPU_VENDOR:-}" = amd ]; then
      die "AMD GPU ${GS_GPU_PCI_ADDRESS:-(no address)}: Xorg on $disp (X config $XORG_CONFIG) hung during startup and survived SIGKILL, so it is stuck in the kernel and the walk over :${DISPLAY#:}..:$(( ${DISPLAY#:} + 9 )) stops at $disp. Read /var/log/Xorg.${n}.log and the node's dmesg; the node likely needs a reboot."
    fi
    die "Xorg on $disp hung during startup and survived SIGKILL — GPU display engine is wedged (check the node's dmesg for 'nvidia-modeset ... waiting for GPU progress'); the node likely needs a reboot."
  fi
  return 1
}

# Is some X server bound to :$1's abstract socket in our network namespace?
# Pods are hostNetwork, so this sees the host's and other pods' X servers even
# though their /tmp lock files and PIDs are invisible from here.
_x_socket_bound() {
  grep -qs "@/tmp/.X11-unix/X${1}\$" /proc/net/unix
}

# Never start a GPU Xorg while another streamer's Xorg still owns the display: a
# second nvidia modeset against a GPU whose display is held (previous pod still
# tearing down, or its Xorg wedged in nvidia-modeset) hangs silently and can
# wedge the display engine for the whole node. Our own servers are tagged with
# _GS_STREAMER on the root window; an untagged live X is a host desktop, which
# the walk + dummy fallback in start_xorg handles.
_wait_for_foreign_streamer_x() {
  local start_n="${DISPLAY#:}" n held how announced=0
  local max="${GS_FOREIGN_X_WAIT:-60}"
  local deadline=$((SECONDS + max))
  while :; do
    held=""
    for n in $(seq "$start_n" $((start_n + 9))); do
      _x_socket_bound "$n" || continue
      if ! timeout 5 xdpyinfo -display ":$n" >/dev/null 2>&1; then
        held=":$n"; how="bound but not answering"; break
      fi
      if timeout 5 xprop -display ":$n" -root _GS_STREAMER 2>/dev/null | grep -q '='; then
        held=":$n"; how="owned by another streamer pod"; break
      fi
    done
    [ -z "$held" ] && return 0
    if [ "$SECONDS" -ge "$deadline" ]; then
      # S3-D12, S3-D23: on AMD the holder is another GPU Job on this node, and the
      # nvidia-modeset advice of the die below does not apply.
      if [ "${GS_GPU_VENDOR:-}" = amd ]; then
        die "AMD GPU ${GS_GPU_PCI_ADDRESS:-(no address)}: another GPU Job on this node (a stream, demo, render or bake) still holds $held: its X server is $how after ${max}s. One GPU Job per node is the limit, so this pod does not start a second X server. Wait for that Job to end. If no GPU Job runs on this node, an X server outside the streamer pods holds $held: set GS_X_DISPLAY_BASE to move the scanned range :$start_n..:$((start_n + 9))."
      fi
      die "X server on $held is $how after ${max}s — a previous streamer pod on this node never released the GPU display (still running, or its Xorg is wedged in nvidia-modeset). Not starting a second GPU Xorg against it. If no other streamer pod is running on the node, it needs a reboot."
    fi
    if [ "$announced" -eq 0 ]; then
      log "xorg: $held is $how — waiting up to ${max}s for it to go away"
      announced=1
    fi
    sleep 3
  done
}

# Enable NVIDIA persistence mode before the first Xorg modeset. With it off the
# driver tears down + reinitialises GPU state every time the last client
# disconnects; that repeated cold init is a known trigger for the modeset hang
# on this GTX 980 + 580 combo. `-pm 1` keeps the driver resident so modeset runs
# against already-initialised state. Best-effort: missing nvidia-smi or a denied
# write must never block boot, so warn + continue. Idempotent (persists at the
# driver level until reboot), so running it every boot is harmless.
enable_gpu_persistence() {
  # S3-D12: AMD has no persistence mode. On AMD this returns at once and says nothing,
  # whether or not the image has nvidia-smi.
  if [ "${GS_GPU_VENDOR:-}" = amd ]; then return 0; fi
  command -v nvidia-smi >/dev/null 2>&1 || { warn "nvidia-smi not found — skipping persistence mode"; return 0; }
  if timeout 15 nvidia-smi -pm 1 >/dev/null 2>&1; then
    log "nvidia persistence mode enabled (-pm 1)"
  else
    warn "could not enable nvidia persistence mode (-pm 1) — continuing"
  fi
}

# Fail fast on a node whose GPU can't run cs2 at all. Without this the boot looks
# healthy for ~40s (Xorg quietly falls back to the dummy config, Steam logs in)
# and only ends in a bare segfault inside librendersystemvulkan. Detection only —
# every check either dies with a named cause or continues untouched.
# GS_SKIP_GPU_PREFLIGHT=1 bypasses.
preflight_gpu() {
  case "${GS_SKIP_GPU_PREFLIGHT:-0}" in
    1|on|true|yes) log "gpu preflight: skipped (GS_SKIP_GPU_PREFLIGHT)"; return 0 ;;
  esac

  # WSL2 hands the GPU through /dev/dxg: no DRM scanout (so the nvidia X always
  # reports "no screens found") and no Vulkan WSI. cs2 can never run here.
  local kern; kern=$(uname -r 2>/dev/null)
  if [ -e /dev/dxg ] || printf '%s' "$kern" | grep -qi 'microsoft\|wsl'; then
    die "node is WSL2 (kernel '$kern') — the GPU has no DRM scanout and no Vulkan WSI, so cs2 segfaults on renderer init. Keep game-streamer pods off this node (taint / nodeSelector), or set GS_SKIP_GPU_PREFLIGHT=1 to try anyway."
  fi

  command -v vulkaninfo >/dev/null 2>&1 \
    || { warn "gpu preflight: vulkaninfo not installed — skipping Vulkan checks"; return 0; }

  # The Vulkan checks need a running X server: preflight_vulkan runs them after
  # start_xorg (setup-steam.sh).
}

# preflight_vulkan: the Vulkan half of the GPU preflight (S3-D11). setup-steam.sh calls it
# right after start_xorg: vulkaninfo 1.3.275 exits 1 without an X display, so these checks
# never ran while they sat in preflight_gpu. One timeout 30 vulkaninfo run, with its stderr
# in $LOG_DIR/vulkaninfo.err, feeds every check and $LOG_DIR/gpu_identity. On AMD a failed
# check dies with a message that names the GPU address. On NVIDIA and with no vendor set,
# each finding only WARNs, with today's text, until the NVIDIA hardware pass (S3-T19).
# GS_SKIP_GPU_PREFLIGHT=1 skips the checks, the dies and vkcube; on AMD it still writes
# gpu_identity, best effort. The output is matched with here-strings and never piped into
# grep -q (S3-D31): past the 64 KB pipe buffer such a pipe can read a present pattern as
# missing.
preflight_vulkan() {
  local out="" addr="${GS_GPU_PCI_ADDRESS:-}"
  case "${GS_SKIP_GPU_PREFLIGHT:-0}" in
    1|on|true|yes)
      if [ "${GS_GPU_VENDOR:-}" = amd ]; then
        out=$(timeout 30 vulkaninfo 2>"$LOG_DIR/vulkaninfo.err") || true
        _gs_vk_identity "$out"
      fi
      return 0
      ;;
  esac
  case "${GS_GPU_VENDOR:-}" in
    ''|amd|nvidia) ;;
    *) warn "gpu preflight: GS_GPU_VENDOR='$GS_GPU_VENDOR' is neither amd nor nvidia; running the NVIDIA path" ;;
  esac
  if [ "${GS_GPU_VENDOR:-}" = amd ]; then
    if ! _gs_pci_check "$addr"; then
      if [ -z "$addr" ]; then _GS_PCI_FAIL="presence (GS_GPU_PCI_ADDRESS is empty or unset)"; fi
      die "AMD GPU address '$addr' (GS_GPU_PCI_ADDRESS) failed the ${_GS_PCI_FAIL} check, so this pod has no usable GPU. Compare it with 'lspci -D' on the node."
    fi
  elif ! command -v vulkaninfo >/dev/null 2>&1; then
    return 0
  fi
  out=$(timeout 30 vulkaninfo 2>"$LOG_DIR/vulkaninfo.err") || true
  _gs_vk_identity "$out"
  if [ "${GS_GPU_VENDOR:-}" = amd ]; then
    _preflight_vulkan_checks "$out"
  else
    # Until S3-T19 passes, a failed check WARNs with today's text instead of dying. A
    # separate commit after T19 calls _preflight_vulkan_checks directly (S3-D11).
    ( die() { warn "$*"; exit 1; }; _preflight_vulkan_checks "$out" ) || true
  fi
}

# _gs_vk_identity OUT: parses the vulkaninfo text OUT with one awk over a here-string. It
# sets _GS_VK_N to the number of devices, and _GS_VK_NAME, _GS_VK_VID, _GS_VK_DID,
# _GS_VK_INFO and _GS_VK_UUID (lowercase hex without hyphens) for the first device that is
# not a CPU device, or for the first device when all are. When OUT lists a device it writes
# $LOG_DIR/gpu_identity, one key=value per line; on AMD the last key is display_tier (A
# until start_xorg writes $LOG_DIR/display_tier). Always returns 0.
_gs_vk_identity() {
  local kv k v wsi="" tier=""
  _GS_VK_N=0 _GS_VK_NAME="" _GS_VK_VID="" _GS_VK_DID="" _GS_VK_INFO="" _GS_VK_UUID=""
  kv=$(awk '
    /^GPU[0-9]+:$/ { n++; next }
    n == 0 { next }
    { key = $1; v = $0; sub(/^[^=]*=[ \t]*/, "", v) }
    key == "vendorID" && !(n in vid) { vid[n] = v }
    key == "deviceID" && !(n in did) { did[n] = v }
    key == "deviceType" && !(n in typ) { typ[n] = v }
    key == "deviceName" && !(n in name) { name[n] = v }
    key == "driverInfo" && !(n in info) { info[n] = v }
    key == "pipelineCacheUUID" && !(n in uid) { gsub(/-/, "", v); uid[n] = tolower(v) }
    END {
      s = 0
      for (i = 1; i <= n; i++) if (typ[i] != "PHYSICAL_DEVICE_TYPE_CPU") { s = i; break }
      if (s == 0 && n > 0) s = 1
      printf "n=%d\nname=%s\nvid=%s\ndid=%s\ninfo=%s\nuuid=%s\n", n, name[s], vid[s], did[s], info[s], uid[s]
    }' <<<"$1") || kv=""
  while IFS='=' read -r k v; do
    case "$k" in
      n) _GS_VK_N="$v" ;;
      name) _GS_VK_NAME="$v" ;;
      vid) _GS_VK_VID="$v" ;;
      did) _GS_VK_DID="$v" ;;
      info) _GS_VK_INFO="$v" ;;
      uuid) _GS_VK_UUID="$v" ;;
    esac
  done <<<"$kv"
  [ "${_GS_VK_N:-0}" -gt 0 ] 2>/dev/null || return 0
  { read -r wsi < "$LOG_DIR/wsi_mode" || :; } 2>/dev/null
  {
    printf '%s\n' "name=$_GS_VK_NAME" "vendor_id=$_GS_VK_VID" "device_id=$_GS_VK_DID" \
      "driver_info=$_GS_VK_INFO" "pipeline_cache_uuid=$_GS_VK_UUID" \
      "pci_address=${GS_GPU_PCI_ADDRESS:-}" "render_node=${GS_RENDER_NODE:-}" \
      "source=${GS_GPU_VENDOR_SOURCE:-}" "wsi=$wsi"
    if [ "${GS_GPU_VENDOR:-}" = amd ]; then
      tier=$(gs_display_tier)
      printf 'display_tier=%s\n' "${tier:-A}"
    fi
  } > "$LOG_DIR/gpu_identity"
  return 0
}

# _preflight_vulkan_amd OUT: the AMD checks after the kept ones (S3-D11, S3-E4, S3-E5). It
# logs the device and dies when more than one device is left after the filters or when the
# Vulkan vendor:device differs from sysfs. It WARNs for shader_abort, for another GPU with
# the same vendor:device, for self-detection and for a GS_RENDER_NODE hint that names
# another node. On tier A it then runs the vkcube smoke test; on tier C the self-test in
# start_xorg already ran vkcube on this X server.
_preflight_vulkan_amd() {
  local out="$1" addr="${GS_GPU_PCI_ADDRESS:-}" node="${GS_RENDER_NODE:-}"
  local hint="${GS_RENDER_NODE_HINT:-}" vkid n dir class v d twins="" rc=0
  vkid="${_GS_VK_VID#0x}:${_GS_VK_DID#0x}"
  vkid="${vkid,,}"
  log "gpu preflight: AMD GPU $addr: '$_GS_VK_NAME' ($vkid), driver '$_GS_VK_INFO', render node ${node:-none}, source ${GS_GPU_VENDOR_SOURCE:-none}"
  if [ "$_GS_VK_N" -gt 1 ]; then
    die "AMD GPU $addr: vulkaninfo lists $_GS_VK_N devices after the filters (MESA_VK_DEVICE_SELECT='${MESA_VK_DEVICE_SELECT:-}', VK_LOADER_DRIVERS_SELECT='${VK_LOADER_DRIVERS_SELECT:-}'), so cs2 could render on the wrong one. A MESA_VK_DEVICE_SELECT from the pod env without the trailing '!' lets the other devices through: remove it. Run 'vulkaninfo --summary' in the pod to list them."
  fi
  if [ "$vkid" != "$_GS_PCI_ID" ]; then
    die "AMD GPU $addr: Vulkan reports vendor:device $vkid ('$_GS_VK_NAME') but sysfs has $_GS_PCI_ID for this address, so Vulkan is not using this pod's GPU. Check MESA_VK_DEVICE_SELECT in the pod env and $LOG_DIR/gpu_identity."
  fi
  n=$(grep -ci shader_abort <<<"$out") || true
  if [ "${n:-0}" != 0 ]; then
    warn "gpu preflight: AMD GPU $addr: vulkaninfo mentions shader_abort on $n line(s). Mesa 26.2 and later expose VK_KHR_shader_abort, and RADV turns its pipeline cache off when cs2 enables it, so every start compiles all shaders again. The image's Mesa is older, so another Mesa reached this pod: check driver_info in $LOG_DIR/gpu_identity."
  fi
  for dir in "${GS_SYSFS_ROOT:-/sys}"/bus/pci/devices/*; do
    [ "${dir##*/}" != "$addr" ] || continue
    class="" v="" d=""
    { read -r class < "$dir/class" || :; } 2>/dev/null
    case "$class" in 0x03????) ;; *) continue ;; esac
    { read -r v < "$dir/vendor" || :; } 2>/dev/null
    { read -r d < "$dir/device" || :; } 2>/dev/null
    if [ "${v#0x}:${d#0x}" = "$_GS_PCI_ID" ]; then twins="$twins ${dir##*/}"; fi
  done
  if [ -n "$twins" ]; then
    warn "gpu preflight: AMD GPU $addr: another GPU on this node has the same vendor:device $_GS_PCI_ID (${twins# }). MESA_VK_DEVICE_SELECT=$_GS_PCI_ID! cannot tell them apart, so Vulkan may use the other GPU instead of $addr."
  fi
  if [ "${GS_GPU_VENDOR_SOURCE:-}" = self ]; then
    warn "gpu preflight: AMD GPU $addr was found by self-detection (GS_GPU_VENDOR_SOURCE=self), which is meant for docker run and development; Jobs from the api set GS_GPU_VENDOR and GS_GPU_PCI_ADDRESS."
  fi
  if [ -n "$hint" ] && [ "${hint##*/}" != "${node##*/}" ]; then
    warn "gpu preflight: AMD GPU $addr: GS_RENDER_NODE from the pod env ($hint) differs from the render node derived from sysfs (${node:-none}), which is the one used. Render node numbers change across boots: remove GS_RENDER_NODE from the pod env."
  fi
  if [ "$(gs_display_tier)" != C ]; then
    timeout 20 vkcube --c 60 > "$LOG_DIR/vkcube.log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      die "AMD GPU $addr: the vkcube smoke test (timeout 20 vkcube --c 60 on DISPLAY ${DISPLAY:-}) failed with exit $rc (124 means it timed out), so cs2 cannot present on this X server. See $LOG_DIR/vkcube.log: 'No DRI3 support detected' there means MESA_VK_WSI_DEBUG=sw is missing (see $LOG_DIR/wsi_mode). The device is in $LOG_DIR/gpu_identity."
    fi
  fi
  return 0
}

# _preflight_vulkan_checks OUT: the checks preflight_gpu ran before the split, now over the
# captured vulkaninfo text OUT, then the AMD ones or the vendorID check. On NVIDIA and with
# no vendor, preflight_vulkan runs it with die turned into warn until S3-T19.
_preflight_vulkan_checks() {
  local out="$1"
  # No parseable output means vulkaninfo itself failed — not evidence against
  # the node, so don't fail a working pool on it.
  # On AMD, X is up by now, so no usable output is fatal, and the message carries the
  # vulkaninfo.err tail (S3-E4).
  if ! grep -q 'Instance Extensions' <<<"$out"; then
    if [ "${GS_GPU_VENDOR:-}" = amd ]; then
      local err
      err=$(tail -n 3 "$LOG_DIR/vulkaninfo.err" 2>/dev/null) || err=""
      err="${err//$'\n'/ | }"
      die "AMD GPU ${GS_GPU_PCI_ADDRESS:-}: vulkaninfo gave no usable output after X started (no 'Instance Extensions' section), so cs2 cannot use Vulkan here. The last lines of $LOG_DIR/vulkaninfo.err: ${err:-(empty)}"
    fi
    warn "gpu preflight: vulkaninfo returned nothing usable — skipping Vulkan checks"
    return 0
  fi

  local ext missing=""
  for ext in VK_KHR_surface VK_KHR_xlib_surface; do
    grep -qE "^[[:space:]]*${ext}[[:space:]]*:" <<<"$out" || missing="$missing $ext"
  done
  if [ -n "$missing" ] && [ "${GS_GPU_VENDOR:-}" = amd ]; then
    die "AMD GPU ${GS_GPU_PCI_ADDRESS:-}: the Vulkan loader is missing WSI extension(s):${missing} after X started, so cs2 cannot create a swapchain and would crash on renderer init. The image's Mesa Vulkan driver and loader provide them: check the image build and $LOG_DIR/vulkaninfo.err."
  fi
  [ -n "$missing" ] && die "Vulkan loader on this node is missing WSI extension(s):${missing}. cs2 can't create a swapchain and will segfault on renderer init (Steam logs 'BInit - Unable to initialize Vulkan'). Check the NVIDIA container runtime / ICD mounts on the node."

  # Only a software device (llvmpipe/lavapipe) → the ICD mount is missing; cs2
  # either crashes or renders at single-digit fps.
  if ! grep -qE 'PHYSICAL_DEVICE_TYPE_(DISCRETE|INTEGRATED|VIRTUAL)_GPU' <<<"$out"; then
    if [ "${GS_GPU_VENDOR:-}" = amd ]; then
      die "AMD GPU ${GS_GPU_PCI_ADDRESS:-}: no hardware Vulkan device after X started (only a CPU device such as llvmpipe, or none), so cs2 would crash or render at single-digit fps. Check VK_LOADER_DRIVERS_SELECT='${VK_LOADER_DRIVERS_SELECT:-}' (it must match the RADV driver), $LOG_DIR/vulkaninfo.err and $LOG_DIR/gpu_identity."
    fi
    die "no hardware Vulkan device on this node (only software rasterizer, if any) — the NVIDIA ICD isn't reaching the pod. Check NVIDIA_DRIVER_CAPABILITIES and the container runtime."
  fi

  if [ "${GS_GPU_VENDOR:-}" = amd ]; then
    _preflight_vulkan_amd "$out"
  else
    case "${_GS_VK_VID,,}" in
      0x10de|0x1002) ;;
      *)
        warn "gpu preflight: the Vulkan device '${_GS_VK_NAME}' has vendorID ${_GS_VK_VID:-none}, neither NVIDIA (0x10de) nor AMD (0x1002)"
        return 0
        ;;
    esac
  fi

  log "gpu preflight: ok (Vulkan WSI + hardware device present)"
}

# Walk $DISPLAY..+9 trying to start Xorg with the current $XORG_CONFIG. Sets
# XORG_FOUND to the claimed display (":N") and returns 0, or returns 1 if none
# bound. Kept as a global (not stdout) so _try_start_xorg_on's log lines still
# reach the pod log. Called twice by start_xorg: once with the GPU (nvidia)
# config, then with the offscreen dummy config if the GPU display is held.
_xorg_try_displays() {
  local start_n="${DISPLAY#:}" n
  XORG_FOUND=""
  for n in $(seq "$start_n" $((start_n + 9))); do
    if _try_start_xorg_on "$n"; then XORG_FOUND=":$n"; return 0; fi
  done
  return 1
}

# _xorg_wsi_probe: the Vulkan WSI path for the X server on $DISPLAY, on AMD (S3-D9, change
# C7). start_xorg calls it once that server answers. RADV on an X server without DRI3 fails
# with 'No DRI3 support detected' unless MESA_VK_WSI_DEBUG holds sw, so the probe writes sw
# or hw to $LOG_DIR/wsi_mode, which gs_gpu_env reads in every later shell, and on sw it
# exports MESA_VK_WSI_DEBUG=sw in this shell. A missing DRI3 and a failed or timed-out
# xdpyinfo both give sw (S3-E6). The extension list is captured first and matched second
# (S3-D31): a pipe into grep -q can read a present DRI3 as missing. On tier C
# ($LOG_DIR/display_tier starts with C) it writes hw without asking, because the self-test
# found DRI3 on this server moments before (S3-E27). A preset MESA_VK_WSI_DEBUG is always
# kept; on tier A it WARNs when the preset lacks sw on a server without DRI3 (S3-E5).
# GS_SKIP_GPU_PREFLIGHT does not skip it (S3-E9). Always returns 0.
_xorg_wsi_probe() {
  local ext=""
  if [ "$(gs_display_tier)" = C ]; then
    printf 'hw\n' > "$LOG_DIR/wsi_mode" 2>/dev/null || true
    log "xorg: wsi_mode=hw on $DISPLAY (tier C: its self-test found DRI3)"
    return 0
  fi
  ext=$(timeout 5 xdpyinfo -display "$DISPLAY" -queryExtensions 2>/dev/null) || ext=""
  case "$ext" in
    *DRI3*)
      printf 'hw\n' > "$LOG_DIR/wsi_mode" 2>/dev/null || true
      log "xorg: wsi_mode=hw on $DISPLAY (DRI3 listed)"
      return 0
      ;;
  esac
  printf 'sw\n' > "$LOG_DIR/wsi_mode" 2>/dev/null || true
  case "${MESA_VK_WSI_DEBUG:-}" in
    ''|*sw*) ;;
    *) warn "xorg: MESA_VK_WSI_DEBUG='$MESA_VK_WSI_DEBUG' is preset without sw and is kept, but $DISPLAY lists no DRI3 (or xdpyinfo failed), so RADV can fail with 'No DRI3 support detected'" ;;
  esac
  : "${MESA_VK_WSI_DEBUG:=sw}"
  export MESA_VK_WSI_DEBUG
  log "xorg: wsi_mode=sw on $DISPLAY (no DRI3 listed, or xdpyinfo failed), MESA_VK_WSI_DEBUG=$MESA_VK_WSI_DEBUG"
  return 0
}

# Tier C is opt-in. The image default remains A until a separate approved change.
_GS_DISPLAY_TIER_DEFAULT=A
_GS_TIER_PICK=""

_resolve_display_tier() {
  _GS_TIER_PICK=""
  [ "${GS_GPU_VENDOR:-}" = amd ] || return 0
  rm -f "$LOG_DIR/display_tier"
  local requested="${GS_DISPLAY_TIER:-}"
  case "${MESA_VK_WSI_DEBUG:-}" in
    *sw*)
      _GS_TIER_PICK='A forced:MESA_VK_WSI_DEBUG'
      [ "$requested" != C ] || warn 'tier C requested with MESA_VK_WSI_DEBUG=sw; using tier A'
      return 0
      ;;
  esac
  case "$requested" in
    A|C) _GS_TIER_PICK="$requested requested" ;;
    '') _GS_TIER_PICK="$_GS_DISPLAY_TIER_DEFAULT default" ;;
    *)
      warn "invalid GS_DISPLAY_TIER='$requested'; using image default $_GS_DISPLAY_TIER_DEFAULT"
      _GS_TIER_PICK="$_GS_DISPLAY_TIER_DEFAULT default"
      ;;
  esac
  return 0
}
# Keep the raw server log for the self-test and a line-buffered tagged pod log.
# nohup execs the command, so SPAWNED_PID identifies the server itself.
_spawn_logged_to() {
  local tag="$1" file="$2"
  shift 2
  nohup "$@" > >(tee -a "$file" | awk "${GS_AWK_LINES[@]}" -v t="$tag" \
    '!/Could not resolve keysym XF86|Errors from xkbcomp are not fatal/ {print "["t"] " $0; fflush()}' >&2) 2>&1 &
  SPAWNED_PID=$!
}
# Every persisted PID is paired with comm. Never signal a reused PID.
_tier_c_alive() {
  local pid="${1:-}" comm="${2:-}" now="" state="" proc="${GS_PROC_ROOT:-/proc}"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  IFS= read -r now < "$proc/$pid/comm" 2>/dev/null || return 1
  [ -z "$comm" ] || [ "$now" = "$comm" ] || return 1
  if [ -r "$proc/$pid/stat" ]; then
    IFS= read -r state < "$proc/$pid/stat" || state=""
    state="${state##*) }"
    [ "${state%% *}" != Z ] || return 1
  fi
  return 0
}

_tier_c_read_pid() {
  local pid="" comm=""
  [ -r "$1" ] || return 1
  read -r pid comm < "$1" || return 1
  [ -n "$comm" ] && _tier_c_alive "$pid" "$comm" || return 1
  printf '%s' "$pid"
}

_tier_c_record_pid() {
  local pid="$1" file="$2" comm=""
  IFS= read -r comm < "${GS_PROC_ROOT:-/proc}/$pid/comm" || return 1
  _tier_c_alive "$pid" "$comm" || return 1
  printf '%s %s\n' "$pid" "$comm" > "$file"
}

# Stop Xwayland first, then weston. The combined grace is at most 10+5+2 seconds.
# Plain kill is intentional: a shell function can model a kernel SIGKILL survivor.
_tier_c_stop() {
  local xw="${1:-}" weston="${2:-}" proc="${GS_PROC_ROOT:-/proc}"
  local pid name limit deadline comm="" rc=0 i state=""
  local pids=("$xw" "$weston") names=(Xwayland weston) limits=(10 5) comms=('' '')
  for i in 0 1; do
    pid="${pids[$i]}" name="${names[$i]}" limit="${limits[$i]}"
    _tier_c_alive "$pid" || continue
    IFS= read -r comm < "$proc/$pid/comm" || continue
    comms[i]="$comm"
    log "tier C stop: SIGTERM to $name $pid"
    kill -TERM "$pid" 2>/dev/null || true
    deadline=$((SECONDS + limit))
    while _tier_c_alive "$pid" "$comm" && [ "$SECONDS" -lt "$deadline" ]; do
      sleep 0.5
    done
  done
  for i in 0 1; do
    pid="${pids[$i]}" comm="${comms[$i]}"
    if [ -z "$comm" ] || ! _tier_c_alive "$pid" "$comm"; then continue; fi
    rc=1
    warn "tier C stop: PID $pid ignored SIGTERM, sending SIGKILL"
    kill -KILL "$pid" 2>/dev/null || true
  done
  deadline=$((SECONDS + 2))
  while [ "$SECONDS" -lt "$deadline" ]; do
    local live=0
    for i in 0 1; do
      [ -n "${comms[$i]}" ] && _tier_c_alive "${pids[$i]}" "${comms[$i]}" && live=1
    done
    [ "$live" = 1 ] || break
    sleep 0.5
  done
  for i in 0 1; do
    pid="${pids[$i]}" comm="${comms[$i]}"
    [ -n "$comm" ] || continue
    if _tier_c_alive "$pid" "$comm"; then
      IFS= read -r state < "$proc/$pid/stat" || state='unknown'
      state="${state##*) }"
      warn "tier C stop: PID $pid survived SIGKILL (state ${state%% *})"
    else
      wait "$pid" 2>/dev/null || true
    fi
  done
  return "$rc"
}

_tier_c_cleanup() {
  rm -rf /tmp/gs-weston
  rm -f "$LOG_DIR/weston.pid" "$LOG_DIR/xwayland.pid"
}
# Stage helpers return through these globals; they never print a value into a caller's
# command substitution. The coordinator writes fallback status before stopping anything.
_GS_TIER_REASON=""
_GS_TIER_DETAIL=""
_GS_TIER_LOG=""
_GS_TIER_WESTON=""
_GS_TIER_XW=""

_tier_c_fail() {
  _GS_TIER_REASON="$1" _GS_TIER_DETAIL="$2" _GS_TIER_LOG="${3:-}"
  return 1
}

_tier_c_exit_detail() {
  local pid="$1" rc=0
  wait "$pid" 2>/dev/null || rc=$?
  if [ "$rc" -gt 128 ]; then
    _GS_TIER_DETAIL="signal $((rc-128))"
  else
    _GS_TIER_DETAIL="exit $rc"
  fi
}

_tier_c_check_weston() {
  local file="$LOG_DIR/weston.log" renderer="" device="" deadline=$((SECONDS+5))
  while :; do
    if ! _tier_c_alive "$_GS_TIER_WESTON"; then
      _tier_c_exit_detail "$_GS_TIER_WESTON"
      _tier_c_fail weston-failed "$_GS_TIER_DETAIL" "$file"
      return 1
    fi
    renderer=$(awk '/GL renderer:/{line=$0} END{print line}' "$file" 2>/dev/null) || renderer=""
    [ -z "$renderer" ] || break
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 0.2
  done
  case "$renderer" in
    *radeonsi*) ;;
    *) _tier_c_fail weston-renderer "${renderer:-no GL renderer line within 5s}" "$file"; return 1 ;;
  esac
  if grep -qF 'warning: failed to query rendering device from EGL' "$file"; then
    _tier_c_fail device-check 'unknown: failed to query rendering device from EGL' "$file"
    return 1
  fi
  device=$(awk '/Using rendering device:/{sub(/^.*Using rendering device:[[:space:]]*/, ""); line=$0} END{print line}' "$file")
  if [ -n "$device" ] && [ "$device" != "${GS_RENDER_NODE:-}" ]; then
    _tier_c_fail device-check "mismatch: weston opened $device, expected ${GS_RENDER_NODE:-none}" "$file"
    return 1
  fi
  return 0
}

_tier_c_start_weston() {
  rm -rf /tmp/gs-weston
  mkdir -m 0700 /tmp/gs-weston || { _tier_c_fail weston-failed 'cannot create private runtime directory'; return 1; }
  : > "$LOG_DIR/weston.log"
  _spawn_logged_to weston "$LOG_DIR/weston.log" env -u DISPLAY -u WAYLAND_DISPLAY \
    -u WAYLAND_SOCKET XDG_RUNTIME_DIR=/tmp/gs-weston weston --backend=headless \
    --renderer=gl --shell=kiosk --no-config --idle-time=0 --width="$CS2_WIDTH" \
    --height="$CS2_HEIGHT" --socket=gs-weston
  _GS_TIER_WESTON="$SPAWNED_PID"
  local deadline=$((SECONDS+10))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if ! _tier_c_alive "$_GS_TIER_WESTON"; then
      _tier_c_exit_detail "$_GS_TIER_WESTON"
      _tier_c_fail weston-failed "$_GS_TIER_DETAIL" "$LOG_DIR/weston.log"
      return 1
    fi
    if [ -e /tmp/gs-weston/gs-weston ]; then
      _tier_c_check_weston
      return $?
    fi
    sleep 0.2
  done
  _tier_c_fail weston-failed 'timeout waiting 10s for /tmp/gs-weston/gs-weston' "$LOG_DIR/weston.log"
}
_GS_TIER_DISPLAY=""

_tier_c_bound() {
  grep -qs "@/tmp/.X11-unix/X${1}\$" "${GS_PROC_ROOT:-/proc}/net/unix"
}

# Match the listening socket, never an accepted connection with the same address.
_tier_c_owns() {
  local n="$1" pid="$2" owner="" inode="" fd target="" proc="${GS_PROC_ROOT:-/proc}"
  owner=$(awk '{print $1+0}' "/tmp/.X${n}-lock" 2>/dev/null) || return 1
  [ "$owner" = "$pid" ] || return 1
  inode=$(awk -v path="@/tmp/.X11-unix/X$n" \
    '$4=="00010000" && $6=="01" && $8==path {print $7}' "$proc/net/unix" 2>/dev/null) || return 1
  [[ "$inode" =~ ^[0-9]+$ ]] || return 1
  for fd in "$proc/$pid/fd/"*; do
    target=$(readlink "$fd" 2>/dev/null) || continue
    [ "$target" != "socket:[$inode]" ] || return 0
  done
  return 1
}

_tier_c_listen_failure() {
  local file="$1" i
  # tee may not have copied the server's last line when kill -0 first fails.
  for ((i=0;i<=5;i++)); do
    if grep -qE 'server already running|Cannot establish any listening sockets' "$file"; then
      return 0
    fi
    [ "$i" = 5 ] || sleep 0.2
  done
  return 1
}

_tier_c_try_displays() {
  local start_n="${DISPLAY#:}" n owner="" file="" deadline rc=0 detail=""
  _GS_TIER_DISPLAY=""
  for ((n=start_n;n<start_n+10;n++)); do
    if timeout 5 xdpyinfo -display ":$n" >/dev/null 2>&1; then continue; fi
    if [ -e "/tmp/.X${n}-lock" ]; then
      owner=$(awk '{print $1+0}' "/tmp/.X${n}-lock" 2>/dev/null) || owner=""
      if [[ "$owner" =~ ^[1-9][0-9]*$ ]] && kill -0 "$owner" 2>/dev/null; then continue; fi
      rm -f "/tmp/.X${n}-lock" "/tmp/.X11-unix/X${n}"
    fi
    _tier_c_bound "$n" && continue
    file="$LOG_DIR/xwayland.$n.log"
    : > "$file"
    _spawn_logged_to xwayland "$file" env -u WAYLAND_SOCKET \
      WAYLAND_DISPLAY=/tmp/gs-weston/gs-weston Xwayland ":$n" \
      -geometry "${CS2_WIDTH}x${CS2_HEIGHT}" -noreset -nolisten tcp -listen unix \
      -s 0 -fakescreenfps 60 -verbose 3
    _GS_TIER_XW="$SPAWNED_PID"
    deadline=$((SECONDS+10))
    while [ "$SECONDS" -lt "$deadline" ]; do
      if ! _tier_c_alive "$_GS_TIER_XW"; then
        rc=0
        wait "$_GS_TIER_XW" 2>/dev/null || rc=$?
        if _tier_c_listen_failure "$file"; then
          _tier_c_stop "$_GS_TIER_XW" '' || true
          _GS_TIER_XW=""
          break
        fi
        detail="exit $rc"
        [ "$rc" -le 128 ] || detail="signal $((rc-128))"
        _tier_c_fail xwayland-failed "$detail: $(tail -n 1 "$file")" "$file"
        return 1
      fi
      if timeout 5 xdpyinfo -display ":$n" >/dev/null 2>&1; then
        if _tier_c_owns "$n" "$_GS_TIER_XW"; then
          _GS_TIER_DISPLAY=":$n"
          return 0
        fi
        log "tier C: ownership mismatch on :$n; stopping our Xwayland and trying next display"
        _tier_c_stop "$_GS_TIER_XW" '' || true
        _GS_TIER_XW=""
        break
      fi
      sleep 0.5
    done
    if [ -n "$_GS_TIER_XW" ]; then
      _tier_c_fail xwayland-failed 'timeout waiting 10s for Xwayland readiness' "$file"
      return 1
    fi
  done
  _tier_c_fail no-free-display "all displays :$start_n..:$((start_n+9)) are held or failed ownership"
}
# Return a de-duplicated list of render-node targets for one server, or no value
# when the fd directory is unreadable. No GPU state is written.
_tier_c_render_nodes() {
  local dir="${GS_PROC_ROOT:-/proc}/$1/fd" fd target="" nodes=" "
  [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || return 1
  for fd in "$dir/"*; do
    [ -L "$fd" ] || continue
    target=$(readlink "$fd" 2>/dev/null) || return 1
    case "$target" in
      /dev/dri/renderD[0-9]*)
        case "$nodes" in *" $target "*) ;; *) nodes="$nodes$target " ;; esac
        ;;
    esac
  done
  printf '%s' "${nodes# }"
}

_tier_c_check_devices() {
  local a="" b="" node="" device="" vendor="" sys="${GS_SYSFS_ROOT:-/sys}"
  a=$(_tier_c_render_nodes "$_GS_TIER_WESTON") || a=""
  b=$(_tier_c_render_nodes "$_GS_TIER_XW") || b=""
  if [ -z "$a" ] || [ -z "$b" ]; then
    _tier_c_fail device-check "unknown: render fds weston=<$a> Xwayland=<$b>"
    return 1
  fi
  if [ "$a" != "${GS_RENDER_NODE:-} " ] || [ "$b" != "$a" ]; then
    _tier_c_fail device-check "mismatch: render fds weston=<$a> Xwayland=<$b>, expected ${GS_RENDER_NODE:-none}"
    return 1
  fi
  node="${GS_RENDER_NODE##*/}"
  device=$(readlink -f "$sys/class/drm/$node/device" 2>/dev/null) || device=""
  if [ -z "$device" ] || ! IFS= read -r vendor < "$device/vendor"; then
    _tier_c_fail device-check 'unknown: unreadable render-node sysfs'
    return 1
  fi
  if [ "${device##*/}" != "${GS_GPU_PCI_ADDRESS:-}" ] || [ "$vendor" != 0x1002 ]; then
    _tier_c_fail device-check "mismatch: sysfs address=${device##*/} vendor=$vendor"
    return 1
  fi
  return 0
}

_tier_c_servers_alive() {
  if ! _tier_c_alive "$_GS_TIER_WESTON"; then
    _tier_c_exit_detail "$_GS_TIER_WESTON"
    _tier_c_fail weston-failed "$_GS_TIER_DETAIL" "$LOG_DIR/weston.log"
    return 1
  fi
  if ! _tier_c_alive "$_GS_TIER_XW"; then
    _tier_c_exit_detail "$_GS_TIER_XW"
    _tier_c_fail xwayland-failed "$_GS_TIER_DETAIL" "$LOG_DIR/xwayland.${_GS_TIER_DISPLAY#:}.log"
    return 1
  fi
  return 0
}

_tier_c_selftest() {
  local disp="$_GS_TIER_DISPLAY" file="$LOG_DIR/xwayland.${_GS_TIER_DISPLAY#:}.log"
  local out="" root="" mode="" vk="" selected="" rc=0 line=""
  _tier_c_servers_alive || return 1
  line=$(awk '/Failed to initialize glamor|Failed to initialize dri3|Refusing to try glamor on llvmpipe|wl_drm.*not supported|Missing Wayland requirements/{bad=$0} END{print bad}' "$file")
  if [ -n "$line" ]; then _tier_c_fail no-dri3 "$line" "$file"; return 1; fi
  out=$(timeout 5 xdpyinfo -display "$disp" -queryExtensions 2>/dev/null) || out=""
  _tier_c_servers_alive || return 1
  case "$out" in *DRI3*) ;; *) _tier_c_fail no-dri3 'DRI3 absent or xdpyinfo timed out' "$file"; return 1 ;; esac
  _tier_c_check_devices || return 1
  out=$(timeout 5 xdpyinfo -display "$disp" 2>/dev/null) || out=""
  root=$(awk '/dimensions:/{value=$2} END{print value}' <<< "$out")
  out=$(timeout 5 xrandr -display "$disp" --current 2>/dev/null) || out=""
  mode=$(awk '/\*/{value=$1} END{print value}' <<< "$out")
  _tier_c_servers_alive || return 1
  if [ "$root" != "$CS2_DISPLAY_RES" ] || [ "$mode" != "$CS2_DISPLAY_RES" ]; then
    _tier_c_fail root-size "root=${root:-unknown} mode=${mode:-unknown} expected=$CS2_DISPLAY_RES" "$file"
    return 1
  fi
  vk=$(DISPLAY="$disp" env -u MESA_VK_WSI_DEBUG -u WAYLAND_DISPLAY -u WAYLAND_SOCKET \
    timeout 20 vkcube --c 60 2>&1) || rc=$?
  _tier_c_servers_alive || return 1
  selected=$(awk '/Selected GPU/{line=$0} END{print line}' <<< "$vk")
  if [ "$rc" != 0 ] || ! [[ "$selected" == *RADV* && "$selected" != *Cpu* ]]; then
    line=$(tail -n 1 <<< "$vk")
    _tier_c_fail vkcube-failed "exit $rc: $line" "$file"
    return 1
  fi
  return 0
}
_start_tier_c() {
  local old_xw="" old_weston="" last=""
  old_xw=$(_tier_c_read_pid "$LOG_DIR/xwayland.pid") || old_xw=""
  old_weston=$(_tier_c_read_pid "$LOG_DIR/weston.pid") || old_weston=""
  _tier_c_stop "$old_xw" "$old_weston" || true
  _tier_c_cleanup
  _GS_TIER_XW="" _GS_TIER_WESTON="" _GS_TIER_REASON="" _GS_TIER_DETAIL="" _GS_TIER_LOG=""
  if [ -z "${GS_RENDER_NODE:-}" ] || [ ! -e "$GS_RENDER_NODE" ]; then
    _tier_c_fail no-render-node "render node ${GS_RENDER_NODE:-unset} is unavailable" || true
  elif _tier_c_start_weston && _tier_c_try_displays && _tier_c_selftest; then
    if _tier_c_record_pid "$_GS_TIER_WESTON" "$LOG_DIR/weston.pid" \
      && _tier_c_record_pid "$_GS_TIER_XW" "$LOG_DIR/xwayland.pid"; then
      printf '%s\n' "$_GS_TIER_PICK" > "$LOG_DIR/display_tier"
      XORG_FOUND="$_GS_TIER_DISPLAY"
      return 0
    fi
    _tier_c_servers_alive || true
    if [ -z "$_GS_TIER_REASON" ]; then
      _tier_c_fail device-check 'unknown: cannot persist server PID identity' || true
    fi
  fi
  printf 'A fallback:%s\n' "${_GS_TIER_REASON:-unknown}" > "$LOG_DIR/display_tier"
  if [ -n "$_GS_TIER_LOG" ]; then last=$(tail -n 1 "$_GS_TIER_LOG" 2>/dev/null) || last=""; fi
  warn "tier C fallback:${_GS_TIER_REASON:-unknown}: $_GS_TIER_DETAIL${last:+; last log: $last}"
  _tier_c_stop "$_GS_TIER_XW" "$_GS_TIER_WESTON" || true
  _tier_c_cleanup
  return 1
}

_tier_c_running() {
  _tier_c_read_pid "$LOG_DIR/xwayland.pid" >/dev/null || return 1
  _tier_c_read_pid "$LOG_DIR/weston.pid" >/dev/null || return 1
  timeout 5 xdpyinfo -display "$DISPLAY" >/dev/null 2>&1
}
start_xorg() {
  if xorg_running; then
    log "xorg already up on $DISPLAY"
  elif [ "${GS_GPU_VENDOR:-}" = amd ] && [ "$(gs_display_tier)" = C ] \
    && _tier_c_read_pid "$LOG_DIR/xwayland.pid" >/dev/null; then
    die "display server on $DISPLAY is present but tier C is unresponsive or incomplete; see $LOG_DIR/weston.log and $LOG_DIR/xwayland.${DISPLAY#:}.log"
  elif pgrep -x Xorg >/dev/null 2>&1; then
    # Xorg process present but it just failed xorg_running's timeout probe →
    # WEDGED (GPU/DRM modeset hang). It's unkillable (D state) and a fresh Xorg
    # on the same poisoned GPU just re-wedges, so recovery in-pod isn't reliable.
    # Fail loudly so the orchestrator restarts/reschedules instead of the boot
    # hanging invisibly on the dead server (the old failure mode: stuck forever
    # on xdpyinfo right after the status-reporter line, no further logs).
    die "Xorg on $DISPLAY is present but unresponsive (>5s) — GPU/DRM modeset wedge; the node is likely poisoned until reboot. Failing so the pod reschedules."
  else
    _wait_for_foreign_streamer_x
    # Resident-driver state before the first modeset — see enable_gpu_persistence.
    enable_gpu_persistence
    # Host may already be running a desktop on :0 (gnome-shell etc.) and
    # bind-mount /tmp/.X11-unix into the pod — that collides with our
    # bind. Walk forward until we find a display we can actually claim,
    # then re-export DISPLAY so ximagesrc/xdotool/spectator follow.
    local found="" tier=""
    if [ "${GS_GPU_VENDOR:-}" = amd ]; then
      _resolve_display_tier
      tier="${_GS_TIER_PICK%% *}"
    fi
    if [ "${tier:-}" = C ] && _start_tier_c; then
      found="$XORG_FOUND"
    else
      _xorg_try_displays && found="$XORG_FOUND"
    fi

    # COEXIST fallback: the nvidia walk failed with "no screens found" → the
    # GPU's display is owned by another X server (a host Ubuntu desktop on :0, or
    # a leftover Xorg). The GPU only binds ONE X server for scanout, but its
    # render node is SHAREABLE, so retry with the dummy software-framebuffer X on
    # a free display: cs2 still renders Vulkan on the shared render node and
    # vkcapture grabs the frame (X-independent), so the streamer runs alongside a
    # normal desktop. Only Steam's CEF UI renders black (we never capture it).
    # On by default; set GS_DUMMY_FALLBACK=0 to force the node-side fix instead.
    if [ -z "$found" ] && [ "${GS_DUMMY_FALLBACK:-1}" = 1 ] \
       && grep -qs 'no screens found' /var/log/Xorg.*.log; then
      local dummy_cfg="${GS_DUMMY_CONFIG:-}"
      if [ -z "$dummy_cfg" ]; then
        case "$CS2_DISPLAY_RES" in
          2560x1440) dummy_cfg=xorg-coexist-1440p.conf ;;
          *)         dummy_cfg=xorg-coexist-1080p.conf ;;
        esac
      fi
      # S3-D12: AMD gets its own line. The NVIDIA line below keeps its bytes, indent included.
      if [ "${GS_GPU_VENDOR:-}" = amd ]; then
        log "xorg: AMD GPU ${GS_GPU_PCI_ADDRESS:-(no address)}: no display in :${DISPLAY#:}..:$(( ${DISPLAY#:} + 9 )) started with X config $XORG_CONFIG, and /var/log/Xorg.<n>.log reports 'no screens found' (those logs are cleared for the retry); retrying with offscreen dummy X ($dummy_cfg)"
      else
      log "no screens found on every display — GPU scanout unavailable (owned by a host desktop, or the GPU has none); retrying with offscreen dummy X ($dummy_cfg). cs2 renders via the shared GPU render node and vkcapture still captures, provided the node has hardware Vulkan (see preflight_gpu)"
      fi
      export XORG_CONFIG="$dummy_cfg"
      rm -f /var/log/Xorg.*.log 2>/dev/null || true   # clear so a later grep is fresh
      _xorg_try_displays && found="$XORG_FOUND"
    fi

    if [ -z "$found" ]; then
      # S3-D12, S3-E7: on AMD one text replaces both dies below, without systemctl advice.
      if [ "${GS_GPU_VENDOR:-}" = amd ]; then
        die "AMD GPU ${GS_GPU_PCI_ADDRESS:-(no address)}: Xorg failed to start on every display in :${DISPLAY#:}..:$(( ${DISPLAY#:} + 9 )) with X config $XORG_CONFIG. Read /var/log/Xorg.<n>.log for those displays. If other X servers hold that range, set GS_X_DISPLAY_BASE to scan another one."
      fi
      if grep -qs 'no screens found' /var/log/Xorg.*.log; then
        die "Xorg can't get the GPU on this node — :0 is held ('server already running') and the GPU is already bound ('no screens found'), and the offscreen dummy-X fallback also failed. Free the GPU on the node (systemctl set-default multi-user.target && systemctl disable --now display-manager.service && systemctl isolate multi-user.target) or check GS_DUMMY_FALLBACK / the xorg-coexist configs."
      fi
      die "Xorg failed to start on any display in :${DISPLAY#:}..:$(( ${DISPLAY#:} + 9 ))"
    fi
    if [ "$found" != "$DISPLAY" ]; then
      log "xorg: requested $DISPLAY was taken — running on $found instead"
      export DISPLAY="$found"
    fi
  fi

  if [ "${GS_GPU_VENDOR:-}" = amd ] && [ ! -e "$LOG_DIR/display_tier" ]; then
    local line=""
    case "${_GS_TIER_PICK:-}" in
      A*) line=$_GS_TIER_PICK ;;
      '') line='A default' ;;
      *) line='A fallback:unknown'; warn 'tier C returned without a fallback line' ;;
    esac
    printf '%s\n' "$line" > "$LOG_DIR/display_tier"
  fi

  # Pin the resolved display so the next flow (run-demo / run-live, a
  # fresh process) inherits it instead of re-defaulting to :0. common.sh
  # reads this when DISPLAY isn't set in the env.
  printf '%s' "$DISPLAY" > "$LOG_DIR/display" 2>/dev/null || true

  if ! pgrep -x openbox >/dev/null 2>&1; then
    spawn_logged openbox openbox
    sleep 1
    pgrep -x openbox >/dev/null 2>&1 || warn "openbox didn't start"
  fi

  # Open X access so processes spawned outside our pgid can connect.
  xhost +local:           >/dev/null 2>&1 || true
  xhost +SI:localuser:root >/dev/null 2>&1 || true

  # Mark this X as a streamer's — see _wait_for_foreign_streamer_x.
  xprop -root -f _GS_STREAMER 8s -set _GS_STREAMER "${HOSTNAME:-game-streamer}" >/dev/null 2>&1 || true

  # AMD: the Vulkan WSI path for this X server, sw or hw (S3-D9).
  if [ "${GS_GPU_VENDOR:-}" = amd ]; then _xorg_wsi_probe; fi
}

# SIGTERM and wait, so the nvidia driver releases the display in order. Leaving
# Xorg for the container teardown means SIGKILL while it still owns the display.
stop_xorg() {
  if [ "${GS_GPU_VENDOR:-}" = amd ] && [ "$(gs_display_tier)" = C ]; then
    pkill -x openbox 2>/dev/null || true
    local xw="" weston="" rc=0
    xw=$(_tier_c_read_pid "$LOG_DIR/xwayland.pid") || xw=""
    weston=$(_tier_c_read_pid "$LOG_DIR/weston.pid") || weston=""
    _tier_c_stop "$xw" "$weston" || rc=$?
    _tier_c_cleanup
    return "$rc"
  fi
  pkill -x openbox 2>/dev/null || true
  pkill -x Xorg    2>/dev/null || true
  local i
  for i in $(seq 1 20); do
    pgrep -x Xorg >/dev/null 2>&1 || return 0
    sleep 0.5
  done
  warn "Xorg still alive 10s after SIGTERM"
  return 1
}

# Orderly end-of-pod teardown: GPU clients first, then the X server.
shutdown_display() {
  # Always SIGKILL Steam. A clean exit (steam -shutdown) lets Steam run its exit-time
  # shader maintenance: it consolidated away ~15GB of cs2's recorded pipeline caches
  # and dropped entries as "Mismatching key", and every launch after that replayed
  # ~26k pipelines (~9 minutes) before cs2 could start.
  declare -F kill_steam >/dev/null 2>&1 && kill_steam
  sleep 1
  stop_xorg || true
}

list_x_windows() {
  if ! timeout 5 xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
    log "  (no display on $DISPLAY)"
    return
  fi
  local count=0
  while IFS= read -r line; do
    log "  $line"
    count=$((count + 1))
  done < <(
    xwininfo -display "$DISPLAY" -root -tree 2>/dev/null \
      | awk '/"[^"]+"/{ for (i=1;i<=NF;i++) if ($i ~ /"[^"]+"/) { print; break } }' \
      | head -25
  )
  [ "$count" = 0 ] && log "  (no named windows)"
}

# Find the main Steam UI window — largest "Steam"-named window at
# least 500x300. The real client is a child window deep in the X tree;
# xdotool's getwindowgeometry doesn't reliably handle that case.
find_main_steam_window() {
  xwininfo -display "$DISPLAY" -root -tree 2>/dev/null | awk '
    /"Steam":/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+x[0-9]+\+/) {
          split($i, dim, "x")
          w = dim[1]
          sub(/\+.*/, "", dim[2])
          h = dim[2]
          if (w >= 500 && h >= 300) {
            area = w * h
            if (area > best) { best = area; best_id = $1 }
          }
          break
        }
      }
    }
    END { if (best_id != "") print best_id }
  '
}

# The pipe comes up before the UI does, and -applaunch issued before
# UI render sometimes hangs. Waits indefinitely; the api cancels by
# deleting the pod.
wait_for_main_steam_window() {
  log "waiting for the main Steam window"
  local i=0 id
  while :; do
    id=$(find_main_steam_window)
    if [ -n "$id" ]; then
      log "  ready after ${i}s: $id"
      return 0
    fi
    i=$(( i + 1 ))
    if [ $(( i % 15 )) -eq 0 ]; then
      log "  still waiting (${i}s)"
      list_x_windows
    fi
    sleep 1
  done
}

# Missed clicks on shader-skip / cloud-out-of-date dialogs were falling
# through and hitting Steam UI buttons (cancelling the launch, opening
# unrelated panels). Once cs2 is up, hide Steam.
minimize_steam_windows() {
  local main_id friends_id id
  main_id=$(find_main_steam_window)
  friends_id=$(xdotool search --name '^Friends List$' 2>/dev/null | head -1)
  for id in $main_id $friends_id; do
    [ -z "$id" ] && continue
    xdotool windowminimize "$id"            2>/dev/null || true
    wmctrl -ir "$id" -b add,hidden          2>/dev/null || true
    xdotool windowunmap   "$id"             2>/dev/null || true
    xdotool windowmove    "$id" -3000 -3000 2>/dev/null || true
  done
}

# Space activates the default-focused button on Steam's CEF modal
# dialogs (Cloud Out of Date, shader pre-cache, etc).
poke_steam_dialog() {
  local id
  id=$(find_main_steam_window)
  [ -z "$id" ] && return 0
  wmctrl -ia "$id" 2>/dev/null || true
  xdotool windowactivate --sync "$id" 2>/dev/null || true
  sleep 0.1
  xdotool key --clearmodifiers space 2>/dev/null || true
}

# Click "Play anyway" on the "Cloud Out of Date" CEF modal (it ignores keystrokes,
# so poke_steam_dialog won't work). Screenshots the Steam window's centre region
# and confirms the blue button is actually there (node) BEFORE clicking — no
# match => no click (never misclicks the store). Returns 0 only if it clicked.
dismiss_cloud_dialog() {
  command -v xdotool >/dev/null 2>&1 && command -v gst-launch-1.0 >/dev/null 2>&1 \
    && command -v node >/dev/null 2>&1 \
    || { log "dismiss_cloud_dialog: missing tool (xdotool/gst/node)"; return 1; }
  local wid
  wid=$(wmctrl -lx 2>/dev/null | awk '$3=="steamwebhelper.steam" && $NF=="Steam"{print $1; exit}')
  [ -z "$wid" ] && wid=$(find_main_steam_window 2>/dev/null)
  [ -z "$wid" ] && { log "dismiss_cloud_dialog: no Steam window found"; return 1; }

  local X Y WIDTH HEIGHT
  eval "$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null)" \
    || { log "dismiss_cloud_dialog: getwindowgeometry failed for $wid"; return 1; }
  [ "${WIDTH:-0}" -gt 0 ] && [ "${HEIGHT:-0}" -gt 0 ] \
    || { log "dismiss_cloud_dialog: bad geometry ${WIDTH}x${HEIGHT} for $wid"; return 1; }

  # Centre region where the modal sits (width rounded to /4 for RGBA, no stride).
  local cw ch x1 y1 x2 y2
  cw=$(( (WIDTH * 60 / 100) & ~3 )); ch=$(( HEIGHT * 55 / 100 ))
  x1=$(( X + WIDTH*20/100 )); y1=$(( Y + HEIGHT*25/100 ))
  x2=$(( x1 + cw - 1 ));      y2=$(( y1 + ch - 1 ))

  local raw="${LOG_DIR:-/tmp}/cloud-modal.rgba"
  gst-launch-1.0 -q ximagesrc display-name="${DISPLAY:-:0}" startx="$x1" starty="$y1" \
    endx="$x2" endy="$y2" use-damage=0 num-buffers=1 \
    ! videoconvert ! video/x-raw,format=RGBA ! filesink location="$raw" >/dev/null 2>&1 \
    || { log "dismiss_cloud_dialog: ximagesrc capture failed (${x1},${y1})-(${x2},${y2})"; return 1; }

  # node confirms a button-sized blue blob; prints "cx cy w h count" or nothing.
  local out cx cy bw bh
  out=$(node "$LIB_DIR/find-cloud-button.mjs" "$raw" "$cw" "$ch" 2>&1) \
    || { log "dismiss_cloud_dialog: find-cloud-button error: $out"; return 1; }
  [ -z "$out" ] && { log "dismiss_cloud_dialog: no blue button in ${cw}x${ch} region (window $wid @ ${X},${Y} ${WIDTH}x${HEIGHT})"; return 1; }
  read -r cx cy bw bh _ <<<"$out"
  [ -n "$cx" ] && [ -n "$cy" ] || { log "dismiss_cloud_dialog: unparsable finder output: $out"; return 1; }

  local px=$(( x1 + cx )) py=$(( y1 + cy ))
  log "dismiss_cloud_dialog: Play anyway @ ${px},${py} (button ${bw}x${bh})"
  xdotool mousemove --sync "$px" "$py" click 1 2>/dev/null
  return 0
}
