# shellcheck shell=bash
# CS2 in-game perf helpers — fps cap + cs2_video.txt preset.
# Sourced by src/flows/run-live.sh and src/flows/run-demo.sh; depends on
# log/die/CS2_DIR/SRC_DIR from common.sh.

# Copy resources/video/<preset>.txt -> $CS2_DIR/game/csgo/cfg/cs2_video.txt.
# Overwrites any prior copy so each launch starts from a known state.
# Aborts via die() if CS2_GRAPHICS_PRESET names a preset we don't ship.
apply_cs2_video_preset() {
  local preset="${CS2_GRAPHICS_PRESET:-low}"
  local src="$SRC_DIR/../resources/video/${preset}.txt"
  local dst="$CS2_DIR/game/csgo/cfg/cs2_video.txt"
  if [ ! -f "$src" ]; then
    local available
    available="$(ls "$SRC_DIR/../resources/video/" 2>/dev/null \
                  | sed 's/\.txt$//' | tr '\n' ' ')"
    die "unknown CS2_GRAPHICS_PRESET=$preset (available: ${available:-none})"
  fi
  mkdir -p "$(dirname "$dst")"
  cp -f "$src" "$dst"
  log "  applied graphics preset '$preset' (-> $dst, fps_max=$CS2_FPS_MAX)"
}

# Lines to append to the generated autoexec.cfg. Caller stitches this
# into the heredoc next to HIDE_UI_CMDS / SPEC_BINDS_BLOCK.
#
# These are the runtime convar twin of resources/video/${CS2_GRAPHICS_PRESET}.txt
# — a hand-curated low-quality profile. They run at engine init and are
# the source of truth until we capture real cs2_video.txt files.
cs2_perf_autoexec_block() {
  cat <<'EOF'
// ===== VIDEO / PERFORMANCE =====

// Resolution intentionally NOT set here — launch args force
// -windowed -noborder -width 1920 -height 1080 (required for the
// OpenHud overlay to composite on top). mat_setvideomode would fight
// the launch args and break the overlay.
// mat_setvideomode 1280 960 1

fps_max 0
fps_max_ui 60

// Disable VSync / latency stuff
r_vsync 0
r_dynamic 0

// Shadows & lighting
r_shadows 0
r_shadow_quality 0
r_csgo_water_effects 0

// Textures / detail
r_texture_filtering_quality 0
r_detailtextures 0
r_decals 0
r_drawtracers_firstperson 0

// Effects
r_particle_lighting 0
r_particle_shadows 0
r_volumetric_lighting 0
r_bloom 0

// Anti-aliasing / post
mat_antialias 0
mat_aaquality 0
mat_motion_blur_enabled 0
mat_disable_bloom 1

// Multicore
mat_queue_mode -1

// Reduce input lag
engine_low_latency_sleep_after_client_tick 0

// Misc
cl_autohelp 0
cl_showhelp 0
cl_disablefreezecam 1

echo "LOW SETTINGS LOADED"
EOF
}
