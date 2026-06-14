// Bound keys + director thresholds. Mirror in lib/hud-manager.sh
// spec_static_binds_block / demo_static_binds_block.

export const KEY_SPEC_NEXT        = "F1";
export const KEY_SPEC_PREV        = "F2";
export const KEY_SPEC_JUMP        = "F3";
export const KEY_AUTODIRECTOR_OFF = "F5";

export const KEY_DEMO_TOGGLE    = "Pause";
export const KEY_DEMO_SKIP_BACK = "Home";
export const KEY_DEMO_SKIP_FWD  = "End";
export const KEY_XRAY_TOGGLE    = "x";

export const SPEED_KEY_BY_RATE = {
  "0.25": "Next",
  "0.5":  "semicolon",
  "1":    "Insert",
  "2":    "apostrophe",
  "4":    "Prior",
};

// autoexec binds BACKSPACE → `exec 5stack_exec` for arbitrary commands.
export const EXEC_CFG_KEY = "BackSpace";

export const SLOT_KEYS = [
  "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "minus", "equal",
];

// CAMERA_PRIORITY.md — github.com/zGLados/cs2-better-autodirector.
export const DIRECTOR_TICK_MS = 250;

export const DIRECTOR_DIST_BANDS = [
  { upTo: 300,  bonus: 150 },
  { upTo: 600,  bonus: 120 },
  { upTo: 1000, bonus: 80  },
  { upTo: 1500, bonus: 50  },
  { upTo: 2000, bonus: 20  },
];

export const DIRECTOR_STICKY_BONUS          = 30;
export const DIRECTOR_STICKY_BONUS_CLUTCH   = 10;
export const DIRECTOR_STICKY_PRIORITY_FLOOR = 140;

// Minimum time on a target before any switch is considered. Death of
// the current target bypasses (handled in scoring as forcedByDeath).
// Event bonuses (AWP kill, damage dealer, upset) just bump priority;
// they wait their turn like everything else, otherwise the camera
// whiplashes between simultaneous events.
export const DIRECTOR_MIN_DWELL_MS = 3_000;

// Death of the current target still cuts fast, but NOT instantly: snapping at
// 0ms cuts into cs2's death-cam/PVS transition (a black frame on the new POV, made
// worse by GSI's ~10Hz alive-state lagging cs2's render tick) and reads as frantic.
// A short grace lets the kill register + the new view settle, then cut. Also linger
// a beat on the kill, which is natural broadcast feel. Tune/zero via env if needed.
export const DIRECTOR_DEATH_GRACE_MS = 350;

// Max time on one target before the camera is forced off — keeps the
// view moving when nothing else is more interesting.
export const DIRECTOR_DWELL_MAX_MS = {
  warmup: 5_000, freezetime: 5_000, timeout: 10_000,
  live: 15_000, active: 25_000, clutch: 25_000,
};

export const DIRECTOR_AWP_KILL = { bonus: 200, ttlMs: 8_000,  label: "awp_kill" };
export const DIRECTOR_SSG_KILL = { bonus: 150, ttlMs: 8_000,  label: "ssg_kill" };
export const DIRECTOR_DAMAGE   = { bonus:  40, ttlMs: 5_000,  label: "damage_dealer", minHp: 20 };
export const DIRECTOR_UPSET    = { bonus: 100, ttlMs: 10_000, label: "upset" };

export const DIRECTOR_CLUTCH_ALIVE_THRESHOLD = 4;
export const SNIPER_WEAPONS = new Set(["weapon_awp", "weapon_ssg08"]);

export const STEAMID64_BASE = 76561197960265728n;
