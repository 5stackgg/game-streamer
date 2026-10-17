# S3-U1 and S3-U14: cs2's Steam LaunchOptions (set_cs2_launch_options in src/lib/steam.sh)
# and the HUD argv (start_hud in src/lib/hud-manager.sh). The NVIDIA and unset outputs are
# goldens captured on the upstream commit; the AMD cases after the capture-mode line check
# the S3-D7 composition (S3 C11) and the --ozone-platform=x11 flag (S3 C30).
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # the t_run scripts and stub bodies expand in the child shell
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=lib/golden.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/golden.sh"

STEAMID=76561198000000001
# set_cs2_launch_options the way setup-steam.sh runs it: common.sh first, set -uo pipefail.
LAUNCH='set -uo pipefail; . "$GS_REPO/src/lib/common.sh"; . "$LIB_DIR/steam.sh"; set_cs2_launch_options'
# start_hud with spawn_logged replaced by a printer of the HUD argv.
HUD='set -uo pipefail; . "$GS_REPO/src/lib/common.sh"; . "$LIB_DIR/hud-manager.sh"
spawn_logged() { shift; printf "spawn: %s\n" "$*"; }
start_hud'

# launch_case NAME: one Steam user with a localconfig.vdf, no running Steam client (pgrep
# finds nothing) and a python3 stub in place of the vdf editor. The stub appends the
# LaunchOptions value (its fourth argument) to $T_TMP/launch.txt.
launch_case() {
  t_case "$1"
  mkdir -p "$T_TMP/steam/userdata/$STEAMID/config"
  printf '"UserLocalConfigStore"\n{\n}\n' > "$T_TMP/steam/userdata/$STEAMID/config/localconfig.vdf"
  t_stub pgrep 'exit 1'
  t_stub python3 'printf "%s\n" "$4" >> "$T_TMP/launch.txt"'
}

# launch_text: the output of the last run and the vdf editor's argv, for the goldens.
launch_text() {
  printf 'stdout:\n%s\nstderr:\n%s\npython3:\n%s\n' "$T_STDOUT" "$T_STDERR" "$(t_calls python3)"
}

# hud_case NAME: no running hud-manager (pgrep finds nothing) and an executable stand-in
# for the HUD binary.
hud_case() {
  t_case "$1"
  t_stub pgrep 'exit 1'
  t_stub hud-bin
}

hud_text() {
  printf 'stdout:\n%s\nstderr:\n%s\n' "$T_STDOUT" "$T_STDERR"
}

golden_launch() {
  launch_case "unset vendor: default launch options"
  t_run -- "$LAUNCH"
  t_golden launch-unset-default "$(launch_text)"

  launch_case "unset vendor: clip capture through ximagesrc"
  t_run CLIP_CAPTURE_METHOD=ximagesrc -- "$LAUNCH"
  t_golden launch-unset-ximagesrc "$(launch_text)"

  launch_case "unset vendor: override with %command%"
  t_run 'CS2_LAUNCH_OPTIONS=gamemoderun %command% -novid' -- "$LAUNCH"
  t_golden launch-unset-override-command "$(launch_text)"

  launch_case "unset vendor: override without %command%"
  t_run 'CS2_LAUNCH_OPTIONS=-novid -high' -- "$LAUNCH"
  t_golden launch-unset-override-bare "$(launch_text)"

  launch_case "nvidia: default launch options"
  t_run GS_GPU_VENDOR=nvidia -- "$LAUNCH"
  t_golden launch-nvidia-default "$(launch_text)"

  launch_case "nvidia: override without %command%"
  t_run GS_GPU_VENDOR=nvidia 'CS2_LAUNCH_OPTIONS=-novid -high' -- "$LAUNCH"
  t_golden launch-nvidia-override-bare "$(launch_text)"
}

golden_hud() {
  hud_case "unset vendor: HUD argv"
  t_run HUD_BIN="$T_BIN/hud-bin" -- "$HUD"
  t_golden hud-unset "$(hud_text)"

  hud_case "unset vendor: HUD argv with HUD_GPU=0"
  t_run HUD_BIN="$T_BIN/hud-bin" HUD_GPU=0 -- "$HUD"
  t_golden hud-unset-cpu "$(hud_text)"

  hud_case "nvidia: HUD argv"
  t_run GS_GPU_VENDOR=nvidia HUD_BIN="$T_BIN/hud-bin" -- "$HUD"
  t_golden hud-nvidia "$(hud_text)"

  hud_case "nvidia: HUD argv with HUD_GPU=0"
  t_run GS_GPU_VENDOR=nvidia HUD_BIN="$T_BIN/hud-bin" HUD_GPU=0 -- "$HUD"
  t_golden hud-nvidia-cpu "$(hud_text)"
}

golden_launch
golden_hud
if t_capture_mode; then t_done; fi

# The AMD cases: the fake Radeon 8060S (PCI ID 0x1002:0x1586, renderD128) that part 07's
# gs_gpu_env turns into the loader and device-select pins, and the files start_xorg leaves
# on each display tier.
AMD_ADDR=0000:c6:00.0
V='VK_LOADER_DRIVERS_SELECT=*radeon* MESA_VK_DEVICE_SELECT=1002:1586!'
SDL='SDL_VIDEO_DRIVER=x11 SDL_VIDEODRIVER=x11'

# amd_case NAME TIER: launch_case plus the fake GPU, and wsi_mode and display_tier as
# start_xorg writes them on tier A (sw WSI, the coexist Xorg has no DRI3) or tier C (hw).
amd_case() {
  launch_case "$1"
  t_fake_gpu "$AMD_ADDR" 0x1002 0x1586 0x038000 renderD128
  case "$2" in
    A) printf 'sw\n' > "$T_TMP/log/wsi_mode"; printf 'A default\n' > "$T_TMP/log/display_tier" ;;
    C) printf 'hw\n' > "$T_TMP/log/wsi_mode"; printf 'C requested\n' > "$T_TMP/log/display_tier" ;;
  esac
}

# amd_launch [VAR=VALUE ...]: set_cs2_launch_options with the AMD pod env.
amd_launch() {
  t_run GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS="$AMD_ADDR" "$@" -- "$LAUNCH"
}

# launch_value: the LaunchOptions value the last run wrote.
launch_value() {
  cat "$T_TMP/launch.txt"
}

# word_count WORD: how many words of the last value equal WORD (read -a does not glob).
word_count() {
  local words=() w n=0
  read -r -a words < "$T_TMP/launch.txt"
  for w in "${words[@]}"; do
    [ "$w" = "$1" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# amd_rules [present]: the S3-U1 rules for every AMD value (each vendor word and SDL pin
# once, one %command%, no __GL_SHADER_DISK_CACHE) and, unless the case sets a present mode
# through CS2_LAUNCH_OPTIONS (argument "present"), no MESA_VK_WSI_PRESENT_MODE word.
amd_rules() {
  local w
  for w in 'VK_LOADER_DRIVERS_SELECT=*radeon*' 'MESA_VK_DEVICE_SELECT=1002:1586!' \
    SDL_VIDEO_DRIVER=x11 SDL_VIDEODRIVER=x11 %command%; do
    assert_eq 1 "$(word_count "$w")" "$w once"
  done
  assert_not_contains "$(launch_value)" __GL_SHADER_DISK_CACHE "no __GL_SHADER_DISK_CACHE"
  if [ "${1:-}" != present ]; then
    assert_not_contains "$(launch_value)" MESA_VK_WSI_PRESENT_MODE "no present-mode word"
  fi
}

amd_case "amd tier A: default launch options" A
amd_launch
assert_eq "$V MESA_VK_WSI_DEBUG=sw $SDL OBS_VKCAPTURE=1 %command%" "$(launch_value)" "value"
amd_rules
assert_eq 1 "$(word_count MESA_VK_WSI_DEBUG=sw)" "sw once on tier A"
assert_contains "$T_STDOUT" \
  "set_cs2_launch_options: SteamID $STEAMID -> '$V MESA_VK_WSI_DEBUG=sw $SDL OBS_VKCAPTURE=1 %command%'" \
  "log line"
assert_empty "$T_STDERR" "no WARN"

amd_case "amd tier A: clip capture through ximagesrc" A
amd_launch CLIP_CAPTURE_METHOD=ximagesrc
assert_eq "$V MESA_VK_WSI_DEBUG=sw $SDL %command%" "$(launch_value)" "no OBS_VKCAPTURE word"
amd_rules

amd_case "amd tier A: override with %command%" A
amd_launch 'CS2_LAUNCH_OPTIONS=gamemoderun %command% -novid'
assert_eq "$V MESA_VK_WSI_DEBUG=sw $SDL OBS_VKCAPTURE=1 gamemoderun %command% -novid" \
  "$(launch_value)" "the override comes last"
amd_rules

amd_case "amd tier A: override without %command%" A
amd_launch 'CS2_LAUNCH_OPTIONS=-novid -high'
assert_eq "$V MESA_VK_WSI_DEBUG=sw $SDL OBS_VKCAPTURE=1 %command% -novid -high" \
  "$(launch_value)" "the override follows %command%"
amd_rules

amd_case "amd tier A: override with OBS_VKCAPTURE=0" A
amd_launch 'CS2_LAUNCH_OPTIONS=OBS_VKCAPTURE=0 %command%'
assert_eq "$V MESA_VK_WSI_DEBUG=sw $SDL OBS_VKCAPTURE=0 %command%" "$(launch_value)" \
  "only the override's OBS_VKCAPTURE"
amd_rules

amd_case "amd tier A: override setting an SDL driver" A
amd_launch 'CS2_LAUNCH_OPTIONS=SDL_VIDEO_DRIVER=wayland %command%'
assert_eq "$V MESA_VK_WSI_DEBUG=sw $SDL OBS_VKCAPTURE=1 SDL_VIDEO_DRIVER=wayland %command%" \
  "$(launch_value)" "the override is kept"
assert_empty "$T_STDERR" "no WARN on tier A"

amd_case "amd tier C: default launch options" C
amd_launch
assert_eq "$V $SDL OBS_VKCAPTURE=1 %command%" "$(launch_value)" "value"
amd_rules
assert_not_contains "$(launch_value)" MESA_VK_WSI_DEBUG "no sw on tier C"
assert_empty "$T_STDERR" "no WARN"

amd_case "amd tier C: present mode through the override (the S3-T28 path)" C
amd_launch 'CS2_LAUNCH_OPTIONS=MESA_VK_WSI_PRESENT_MODE=immediate %command%'
assert_eq "$V $SDL OBS_VKCAPTURE=1 MESA_VK_WSI_PRESENT_MODE=immediate %command%" \
  "$(launch_value)" "the word comes right before %command%"
assert_eq 1 "$(word_count MESA_VK_WSI_PRESENT_MODE=immediate)" "present mode once"
amd_rules present
assert_empty "$T_STDERR" "no WARN"

amd_case "amd tier C: override setting an SDL driver" C
amd_launch 'CS2_LAUNCH_OPTIONS=SDL_VIDEO_DRIVER=wayland %command%'
assert_eq "$V $SDL OBS_VKCAPTURE=1 SDL_VIDEO_DRIVER=wayland %command%" "$(launch_value)" \
  "the override is kept"
amd_rules
assert_eq 1 "$(grep -c 'WARN: ' <<< "$T_STDERR")" "one WARN"
assert_contains "$T_STDERR" \
  "WARN: set_cs2_launch_options: CS2_LAUNCH_OPTIONS sets MESA_VK_WSI_DEBUG or an SDL video driver on display tier C" \
  "WARN text"
# amd_hud_case NAME: hud_case plus the fake GPU.
amd_hud_case() {
  hud_case "$1"
  t_fake_gpu "$AMD_ADDR" 0x1002 0x1586 0x038000 renderD128
}

# spawn_line: the HUD argv line of the last run.
spawn_line() {
  grep '^spawn: ' <<< "$T_STDOUT"
}

amd_hud_case "amd: HUD argv"
t_run GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS="$AMD_ADDR" HUD_BIN="$T_BIN/hud-bin" -- "$HUD"
assert_eq "spawn: $T_BIN/hud-bin --no-sandbox --disable-gpu-sandbox --ozone-platform=x11 --mute-audio" \
  "$(spawn_line)" "argv"
assert_contains "$T_STDOUT" "hud-manager: GPU drawing on (HUD_GPU=1)" "log line"

amd_hud_case "amd: HUD argv with HUD_GPU=0"
t_run GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS="$AMD_ADDR" HUD_BIN="$T_BIN/hud-bin" HUD_GPU=0 -- "$HUD"
assert_eq "spawn: $T_BIN/hud-bin --no-sandbox --disable-gpu --enable-transparent-visuals --ozone-platform=x11 --mute-audio" \
  "$(spawn_line)" "argv"
assert_contains "$T_STDOUT" "hud-manager: GPU drawing off (HUD_GPU=0)" "log line"
t_done
