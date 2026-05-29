# shellcheck shell=bash
# Vulkan shader pre-cache progress monitor.
#
# Background: CS2 on Linux uses Vulkan. Before the game runs well Steam
# has to compile every Vulkan pipeline ("Processing Vulkan shaders") via
# fossilize_replay; the compiled binaries land in the NVIDIA GLCache (see
# common.sh / Dockerfile for why that cache must be persisted + sized).
# Historically we Space-pressed that modal away (xorg.sh:poke_steam_dialog)
# to launch fast — but skipping it means the cache never warms, so the
# game stutters. When SHADER_PRECACHE=1 we instead LET the compile run and
# surface its progress here, parsed from the Steam shader log.
#
# Steam writes lines like (confirmed format, appid 730 = CS2):
#   [2024-05-04 13:57:35] Still replaying 730 (80%, 1572280/1941272).
# to $STEAM_HOME/logs/shader_log.txt. We tail it, report the percentage
# via report_status (folded into the launching_cs2 phase — no new API
# status), and drop a freshness marker that wait_for_cs2_process reads to
# avoid timing out / re-issuing applaunch during a long legit compile.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Export the NVIDIA shader disk-cache env for the CS2 process ONLY. Scoped
# to the cs2 launch (called from do_applaunch) rather than exported
# globally, because applying it pod-wide regressed Steam bring-up — the
# Steam client / steamwebhelper / picom / hud-manager all init GL and
# stalled on the cache. cs2's compiled Vulkan shaders still persist in a
# sized, unpruned cache on the library volume; the driver disables the
# cache for root and prunes to ~1 GiB by default, so we re-enable, point it
# at the persistent dir (driver won't create it — common.sh mkdir's it),
# size it to 10 GiB, and disable pruning. Override path via
# GL_SHADER_CACHE_DIR; the values respect any pre-set env.
export_cs2_shader_cache_env() {
  : "${GL_SHADER_CACHE_DIR:=${STEAM_LIBRARY:-/mnt/game-streamer}/nvcache}"
  mkdir -p "$GL_SHADER_CACHE_DIR" 2>/dev/null || true
  export __GL_SHADER_DISK_CACHE="${__GL_SHADER_DISK_CACHE:-1}"
  export __GL_SHADER_DISK_CACHE_PATH="${__GL_SHADER_DISK_CACHE_PATH:-$GL_SHADER_CACHE_DIR}"
  export __GL_SHADER_DISK_CACHE_SIZE="${__GL_SHADER_DISK_CACHE_SIZE:-10737418240}"
  export __GL_SHADER_DISK_CACHE_SKIP_CLEANUP="${__GL_SHADER_DISK_CACHE_SKIP_CLEANUP:-1}"
  log "cs2 shader cache: path=$__GL_SHADER_DISK_CACHE_PATH size=$__GL_SHADER_DISK_CACHE_SIZE"
}

# Path Steam logs shader-replay progress to.
shader_log_file() {
  printf '%s/logs/shader_log.txt' "${STEAM_HOME:-/root/.local/share/Steam}"
}

# Echo "pct done total" parsed from a "Still replaying 730 (NN%, d/t)."
# line, or nothing if it doesn't match.
_parse_shader_line() {
  local line="$1"
  if [[ "$line" =~ \(([0-9]+)%,\ ([0-9]+)/([0-9]+)\) ]]; then
    printf '%s %s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  fi
}

# Last reported precise percentage — in-process throttle so we only
# re-report when it changes. wait_for_cs2_process runs in a single process,
# so a global var is enough; no cross-process marker files and, crucially,
# no fragile background monitor (an earlier bg process died mid-compile and
# froze the UI at 0%).
_SHADER_LAST_REPORT=""

# Parse the shader log and report compile progress; return 0 while a
# compile is actively running (recent log activity, not yet 100%), else 1.
# Call once per wait_for_cs2_process iteration — INLINE in that always-alive
# loop. Reports a PRECISE done/total fraction (1 decimal, matching the web
# stepper's toFixed(1)) so sub-1% movement shows instead of a frozen "0%"
# (1% of CS2's ~723k pipelines is ~7k pipelines — whole-percent ticks crawl).
# Must stay set -u safe — it runs inside the launch loop and a hard error
# would kill it.
shader_report_progress() {
  [ "${SHADER_PROGRESS:-1}" = "1" ] || return 1

  # NB: `compiled`, not `done` — `done` is a bash reserved word; harmless as
  # a read target but a readability trap.
  local f line parsed pct compiled total
  f="$(shader_log_file)"
  [ -f "$f" ] || return 1
  line=$(grep -a 'Still replaying 730 ' "$f" 2>/dev/null | tail -1)
  parsed=$(_parse_shader_line "$line")
  [ -n "$parsed" ] || return 1
  read -r pct compiled total <<<"$parsed"

  # Precise percent from compiled/total. Steam nudges `total` up as it
  # discovers more pipelines, so this wobbles slightly but climbs.
  local precise
  precise=$(awk -v d="${compiled:-0}" -v t="${total:-0}" \
    'BEGIN{ if (t+0<=0){ printf "0.0" } else { p=d*100.0/t; if(p<0)p=0; if(p>100)p=100; printf "%.1f", p } }')

  if [ "$precise" != "${_SHADER_LAST_REPORT:-}" ]; then
    _SHADER_LAST_REPORT="$precise"
    log "processing Vulkan shaders: ${precise}% (${compiled}/${total})"
    # Dedicated processing_shaders stage. progress_stage carries the raw
    # pipeline count ("done / total") so the UI can show scale/ETA — the
    # web stepper already renders progress_stage in parens, and the api
    # stores it in status_history, so this needs no web/api changes.
    # (Steam replays multiple foz DBs, so the count resets between passes —
    # expected; it's a feel-for-progress hint, not a strict monotonic bar.)
    # Live: stored in status_history (same-status ticks coalesced — no
    # bloat). Batch: broadcast_batch_status folds it into boot_stage.
    report_status status=processing_shaders progress="$precise" \
      progress_stage="${compiled} / ${total}" >/dev/null 2>&1 || true
  fi

  # "Actively compiling" = log written recently and not yet at 100%, so the
  # launch loop keeps holding open and doesn't re-issue applaunch.
  local now mtime age
  now=$(date +%s)
  mtime=$(stat -c %Y "$f" 2>/dev/null || echo "$now")
  age=$(( now - mtime ))
  if [ "${pct:-100}" -lt 100 ] && [ "$age" -le "${SHADER_ACTIVE_STALE:-45}" ]; then
    return 0
  fi
  return 1
}
