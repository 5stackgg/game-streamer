# shellcheck shell=bash
# Real-shaped tool output for the AMD unit tests, built in the test so that no large
# fixture is committed. Source it after harness.sh:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/dumps.sh"
#   vk_dump radv > "$T_TMP/vk.out"
#
# vk_dump [-n] [-x EXT] DEVICE...
# Prints what vulkaninfo 1.3.275 (the image's vulkan-tools) prints with no arguments on an
# X display, for the devices named, in that order:
#   radv      Radeon 8060S Graphics (RADV GFX1151), 0x1002:0x1586, integrated (f155ad35)
#   radv1587  the same device with device id 0x1587 (it no longer matches sysfs)
#   abort     radv with VK_KHR_shader_abort among its device extensions
#   lvp       llvmpipe, vendor 0x10005, a CPU device
#   nv        NVIDIA GeForce RTX 3060, 0x10de:0x2504, discrete
#   intel     Intel(R) UHD Graphics 770 (ADL-S GT1), 0x8086:0x4680, integrated
# Every device block ends with 232704 bytes of format properties, so a one-device dump is
# about 237 KB: past the 64 KB pipe buffer and past the size from which a pipe of the dump
# into grep -q fails on every run (about 127 KiB in ubuntu:24.04, grep 3.11), while every
# line the preflight reads sits in the first few KB. -n leaves out the 'Instance
# Extensions' heading line. -x EXT leaves the instance extension EXT out of the list; the
# other sections still name it, as only the instance extension list counts.

VK_INSTANCE_EXTS=(
  VK_EXT_acquire_drm_display:1 VK_EXT_acquire_xlib_display:1 VK_EXT_debug_report:10
  VK_EXT_debug_utils:2 VK_EXT_direct_mode_display:1 VK_EXT_display_surface_counter:1
  VK_EXT_headless_surface:1 VK_EXT_surface_maintenance1:1 VK_EXT_swapchain_colorspace:5
  VK_KHR_device_group_creation:1 VK_KHR_display:23 VK_KHR_external_fence_capabilities:1
  VK_KHR_external_memory_capabilities:1 VK_KHR_external_semaphore_capabilities:1
  VK_KHR_get_display_properties2:1 VK_KHR_get_physical_device_properties2:2
  VK_KHR_get_surface_capabilities2:1 VK_KHR_portability_enumeration:1 VK_KHR_surface:25
  VK_KHR_surface_protected_capabilities:1 VK_KHR_wayland_surface:6 VK_KHR_xcb_surface:6
  VK_KHR_xlib_surface:6 VK_LUNARG_direct_driver_loading:1
)

_VK_PAD=""

# _vk_pad: builds _VK_PAD once, the format properties that end each device block.
_vk_pad() {
  local f feats="" bit block=""
  [ -z "$_VK_PAD" ] || return 0
  for bit in SAMPLED_IMAGE STORAGE_IMAGE COLOR_ATTACHMENT COLOR_ATTACHMENT_BLEND BLIT_SRC \
    BLIT_DST SAMPLED_IMAGE_FILTER_LINEAR TRANSFER_SRC TRANSFER_DST; do
    feats+=$'\t\t'"FORMAT_FEATURE_2_${bit}_BIT"$'\n'
  done
  for f in R8G8B8A8_UNORM R8G8B8A8_SRGB B8G8R8A8_UNORM B8G8R8A8_SRGB A2B10G10R10_UNORM_PACK32 \
    R16G16B16A16_SFLOAT R32G32B32A32_SFLOAT R16G16_UNORM; do
    block+="FORMAT_$f:"$'\n'$'\tlinearTilingFeatures:\n'"$feats"
    block+=$'\toptimalTilingFeatures:\n'"$feats"
    block+=$'\tbufferFeatures:\n\t\tFORMAT_FEATURE_2_UNIFORM_TEXEL_BUFFER_BIT\n'
    block+=$'\t\tFORMAT_FEATURE_2_STORAGE_TEXEL_BUFFER_BIT\n\t\tFORMAT_FEATURE_2_VERTEX_BUFFER_BIT\n\n'
  done
  _VK_PAD="$block"
  while [ "${#_VK_PAD}" -lt 196608 ]; do _VK_PAD+="$_VK_PAD"; done
}

# _vk_dev TOKEN: sets the _VD_* fields of one device.
_vk_dev() {
  _VD_EXTRA=""
  case "$1" in
    radv|radv1587|abort)
      _VD_API="1.4.318 (4211006)" _VD_DRV="25.2.8 (104865800)" _VD_VID=0x1002 _VD_DID=0x1586
      _VD_TYPE=INTEGRATED_GPU _VD_NAME="Radeon 8060S Graphics (RADV GFX1151)"
      _VD_UUID=a8b3c2d1-5e6f-4a7b-8c9d-0e1f2a3b4c5d _VD_DRVID=DRIVER_ID_MESA_RADV
      _VD_DRVNAME=radv _VD_INFO="Mesa 25.2.8-0ubuntu0.24.04.2"
      if [ "$1" = radv1587 ]; then _VD_DID=0x1587; fi
      if [ "$1" = abort ]; then _VD_EXTRA=VK_KHR_shader_abort; fi
      ;;
    lvp)
      _VD_API="1.4.318 (4211006)" _VD_DRV="0.0.1 (1)" _VD_VID=0x10005 _VD_DID=0x0000
      _VD_TYPE=CPU _VD_NAME="llvmpipe (LLVM 20.1.2, 256 bits)"
      _VD_UUID=1f0e2d3c-4b5a-6978-8796-a5b4c3d2e1f0 _VD_DRVID=DRIVER_ID_MESA_LLVMPIPE
      _VD_DRVNAME=llvmpipe _VD_INFO="Mesa 25.2.8-0ubuntu0.24.04.2 (LLVM 20.1.2)"
      ;;
    nv)
      _VD_API="1.4.312 (4211000)" _VD_DRV="580.82.7.0 (2434040256)" _VD_VID=0x10de
      _VD_DID=0x2504 _VD_TYPE=DISCRETE_GPU _VD_NAME="NVIDIA GeForce RTX 3060"
      _VD_UUID=5b9e1a2c-3d4f-5061-7283-94a5b6c7d8e9 _VD_DRVID=DRIVER_ID_NVIDIA_PROPRIETARY
      _VD_DRVNAME="NVIDIA" _VD_INFO="580.82.07"
      ;;
    intel)
      _VD_API="1.4.318 (4211006)" _VD_DRV="25.2.8 (104865800)" _VD_VID=0x8086 _VD_DID=0x4680
      _VD_TYPE=INTEGRATED_GPU _VD_NAME="Intel(R) UHD Graphics 770 (ADL-S GT1)"
      _VD_UUID=c0ffee00-1234-4567-89ab-cdef01234567
      _VD_DRVID=DRIVER_ID_INTEL_OPEN_SOURCE_MESA _VD_DRVNAME="Intel open-source Mesa driver"
      _VD_INFO="Mesa 25.2.8-0ubuntu0.24.04.2"
      ;;
    *) echo "vk_dump: unknown device $1" >&2; return 2 ;;
  esac
}

vk_dump() {
  local head=1 drop="" opt e n=0 i dev ext
  OPTIND=1
  while getopts nx: opt; do
    case "$opt" in
      n) head=0 ;;
      x) drop="$OPTARG" ;;
      *) return 2 ;;
    esac
  done
  shift $((OPTIND - 1))
  _vk_pad
  for e in "${VK_INSTANCE_EXTS[@]}"; do
    if [ "${e%%:*}" != "$drop" ]; then n=$((n + 1)); fi
  done
  printf '==========\nVULKANINFO\n==========\n\nVulkan Instance Version: 1.3.275\n\n\n'
  if [ "$head" = 1 ]; then printf 'Instance Extensions: count = %d\n' "$n"; fi
  printf '===============================\n'
  for e in "${VK_INSTANCE_EXTS[@]}"; do
    if [ "${e%%:*}" != "$drop" ]; then
      printf '\t%-38s : extension revision %s\n' "${e%%:*}" "${e#*:}"
    fi
  done
  printf '\nInstance Layers: count = 1\n==========================\n'
  printf 'VK_LAYER_MESA_device_select Linux device selection layer 1.4.303  version 1\n'
  printf '\tLayer Extensions: count = 0\n\tDevices: count = %d\n' "$#"
  i=0
  for dev in "$@"; do
    _vk_dev "$dev" || return 2
    printf '\t\tGPU id = %d (%s)\n\t\tLayer-Device Extensions: count = 0\n' "$i" "$_VD_NAME"
    i=$((i + 1))
  done
  printf '\nPresentable Surfaces:\n=====================\n'
  i=0
  for dev in "$@"; do
    _vk_dev "$dev"
    printf 'GPU id : %d (%s) [VK_KHR_xcb_surface, VK_KHR_xlib_surface]:\n' "$i" "$_VD_NAME"
    printf '\tSurface type = VK_KHR_xcb_surface\n\tSurface type = VK_KHR_xlib_surface\n'
    printf '\tFormats: count = 2\n\t\tSurfaceFormat[0]:\n\t\t\tformat = FORMAT_B8G8R8A8_SRGB\n'
    printf '\t\t\tcolorSpace = COLOR_SPACE_SRGB_NONLINEAR_KHR\n\t\tSurfaceFormat[1]:\n'
    printf '\t\t\tformat = FORMAT_B8G8R8A8_UNORM\n\t\t\tcolorSpace = COLOR_SPACE_SRGB_NONLINEAR_KHR\n'
    printf '\tPresent Modes: count = 3\n\t\tPRESENT_MODE_IMMEDIATE_KHR\n'
    printf '\t\tPRESENT_MODE_MAILBOX_KHR\n\t\tPRESENT_MODE_FIFO_KHR\n\n'
    i=$((i + 1))
  done
  printf 'Device Groups:\n==============\n'
  i=0
  for dev in "$@"; do
    _vk_dev "$dev"
    printf 'Group %d:\n\tProperties:\n\t\tphysicalDevices: count = 1\n' "$i"
    printf '\t\t\t%s (ID: %d)\n\t\tsubsetAllocation = 0\n\n' "$_VD_NAME" "$i"
    i=$((i + 1))
  done
  printf 'Device Properties and Extensions:\n=================================\n'
  i=0
  for dev in "$@"; do
    _vk_dev "$dev"
    printf 'GPU%d:\nVkPhysicalDeviceProperties:\n---------------------------\n' "$i"
    printf '\tapiVersion        = %s\n\tdriverVersion     = %s\n' "$_VD_API" "$_VD_DRV"
    printf '\tvendorID          = %s\n\tdeviceID          = %s\n' "$_VD_VID" "$_VD_DID"
    printf '\tdeviceType        = PHYSICAL_DEVICE_TYPE_%s\n' "$_VD_TYPE"
    printf '\tdeviceName        = %s\n\tpipelineCacheUUID = %s\n\n' "$_VD_NAME" "$_VD_UUID"
    printf 'VkPhysicalDeviceLimits:\n-----------------------\n'
    printf '\tmaxImageDimension1D                             = 16384\n'
    printf '\tmaxImageDimension2D                             = 16384\n'
    printf '\tmaxImageDimension3D                             = 8192\n'
    printf '\tmaxImageArrayLayers                             = 8192\n'
    printf '\tmaxPushConstantsSize                            = 256\n\n'
    printf 'VkPhysicalDeviceDriverProperties:\n---------------------------------\n'
    printf '\tdriverID           = %s\n\tdriverName         = %s\n' "$_VD_DRVID" "$_VD_DRVNAME"
    printf '\tdriverInfo         = %s\n\tconformanceVersion:\n' "$_VD_INFO"
    printf '\t\tmajor    = 1\n\t\tminor    = 4\n\t\tsubminor = 0\n\t\tpatch    = 0\n\n'
    printf 'VkPhysicalDeviceVulkan12Properties:\n-----------------------------------\n'
    printf '\tdriverID                                             = %s\n' "$_VD_DRVID"
    printf '\tdriverName                                           = %s\n' "$_VD_DRVNAME"
    printf '\tdriverInfo                                           = %s\n\n' "$_VD_INFO"
    ext=3
    if [ -n "$_VD_EXTRA" ]; then ext=4; fi
    printf 'Device Extensions: count = %d\n' "$ext"
    printf '\tVK_EXT_physical_device_drm : extension revision 1\n'
    printf '\tVK_KHR_present_wait        : extension revision 1\n'
    if [ -n "$_VD_EXTRA" ]; then printf '\t%-26s : extension revision 1\n' "$_VD_EXTRA"; fi
    printf '\tVK_KHR_swapchain           : extension revision 70\n\n'
    printf 'Format Properties:\n==================\n%s' "$_VK_PAD"
    i=$((i + 1))
  done
}

# xdpy_dump [-x EXT]
# Prints what xdpyinfo -queryExtensions (x11-utils 7.7) prints for an X.Org 21.1.12 server
# on :20 with one 1920x1080 screen: the server lines, the extensions sorted as xdpyinfo
# sorts them, each with its opcode, and the screen with 960 visuals, which make the dump
# about 237 KB, past the size from which a pipe into grep -q misses on every run. -x EXT
# leaves the extension EXT out; DRI3 appears nowhere else in the dump.
XDPY_EXTS=(
  "BIG-REQUESTS|opcode: 133" "Composite|opcode: 142"
  "DAMAGE|opcode: 143, base event: 91, base error: 152"
  "DOUBLE-BUFFER|opcode: 145, base error: 153" "DPMS|opcode: 147"
  "DRI2|opcode: 155, base event: 119" "DRI3|opcode: 149"
  "GLX|opcode: 152, base event: 95, base error: 158" "Generic Event Extension|opcode: 128"
  "MIT-SCREEN-SAVER|opcode: 144, base event: 92"
  "MIT-SHM|opcode: 130, base event: 65, base error: 128" "Present|opcode: 148"
  "RANDR|opcode: 140, base event: 89, base error: 147" "RECORD|opcode: 146, base error: 154"
  "RENDER|opcode: 139, base error: 142"
  "SECURITY|opcode: 137, base event: 86, base error: 138"
  "SGI-GLX|opcode: 152, base event: 95, base error: 158" "SHAPE|opcode: 129, base event: 64"
  "SYNC|opcode: 134, base event: 83, base error: 134" "X-Resource|opcode: 150"
  "XC-MISC|opcode: 136" "XFIXES|opcode: 138, base event: 87, base error: 140"
  "XFree86-DGA|opcode: 154, base event: 112, base error: 179"
  "XFree86-VidModeExtension|opcode: 153, base error: 172" "XINERAMA|opcode: 141"
  "XInputExtension|opcode: 131, base event: 66, base error: 129"
  "XKEYBOARD|opcode: 135, base event: 85, base error: 137" "XTEST|opcode: 132"
  "XVideo|opcode: 151, base event: 93, base error: 155"
)

_XD_VIS=""

xdpy_dump() {
  local drop="" opt e n=0 i class blk
  OPTIND=1
  while getopts x: opt; do
    case "$opt" in
      x) drop="$OPTARG" ;;
      *) return 2 ;;
    esac
  done
  shift $((OPTIND - 1))
  if [ -z "$_XD_VIS" ]; then
    for ((i = 0; i < 960; i++)); do
      class=TrueColor
      if [ $((i % 2)) = 1 ]; then class=DirectColor; fi
      printf -v blk '  visual:\n    visual id:    0x%x\n    class:    %s\n' $((i + 33)) "$class"
      _XD_VIS+="$blk"
      _XD_VIS+=$'    depth:    24 planes\n    available colormap entries:    256 per subfield\n'
      _XD_VIS+=$'    red, green, blue masks:    0xff0000, 0xff00, 0xff\n'
      _XD_VIS+=$'    significant bits in color specification:    8 bits\n'
    done
  fi
  for e in "${XDPY_EXTS[@]}"; do
    if [ "${e%%|*}" != "$drop" ]; then n=$((n + 1)); fi
  done
  printf 'name of display:    :20\nversion number:    11.0\n'
  printf 'vendor string:    The X.Org Foundation\nvendor release number:    12101012\n'
  printf 'X.Org version: 21.1.12\nmaximum request size:  16777212 bytes\n'
  printf 'motion buffer size:  256\nbitmap unit, bit order, padding:    32, LSBFirst, 32\n'
  printf 'image byte order:    LSBFirst\nnumber of supported pixmap formats:    7\n'
  printf 'supported pixmap formats:\n'
  for e in 1:1 4:8 8:8 15:16 16:16 24:32 32:32; do
    printf '    depth %s, bits_per_pixel %s, scanline_pad 32\n' "${e%%:*}" "${e#*:}"
  done
  printf 'keycode range:    minimum 8, maximum 255\nfocus:  None\n'
  printf 'number of extensions:    %d\n' "$n"
  for e in "${XDPY_EXTS[@]}"; do
    if [ "${e%%|*}" != "$drop" ]; then printf '    %s  (%s)\n' "${e%%|*}" "${e#*|}"; fi
  done
  printf 'default screen number:    0\nnumber of screens:    1\n\nscreen #0:\n'
  printf '  dimensions:    1920x1080 pixels (508x285 millimeters)\n'
  printf '  resolution:    96x96 dots per inch\n  depths (7):    24, 1, 4, 8, 15, 16, 32\n'
  printf '  root window id:    0x4ad\n  depth of root window:    24 planes\n'
  printf '  number of colormaps:    minimum 1, maximum 1\n  default colormap:    0x20\n'
  printf '  default number of colormap cells:    256\n'
  printf '  preallocated pixels:    black 0, white 16777215\n'
  printf '  options:    backing-store WHEN MAPPED, save-unders NO\n'
  printf '  largest cursor:    64x64\n  current input event mask:    0xda0000\n'
  printf '    PropertyChangeMask       SubstructureRedirectMask FocusChangeMask\n'
  printf '    ColormapChangeMask\n  number of visuals:    960\n  default visual id:  0x21\n'
  printf '%s' "$_XD_VIS"
}
