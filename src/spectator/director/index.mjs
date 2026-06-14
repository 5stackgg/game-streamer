import process from "node:process";

import {
  DIRECTOR_MIN_DWELL_MS,
  DIRECTOR_DEATH_GRACE_MS,
  DIRECTOR_TICK_MS,
  KEY_AUTODIRECTOR_OFF,
} from "../constants.mjs";
import { sendKey } from "../cs2/input.mjs";
import { gsiState } from "../state/gsi.mjs";

import { detectEventsAndApplyBonuses } from "./events.mjs";
import { pickDirectorTarget } from "./scoring.mjs";
import { switchSpecTo } from "./switch.mjs";

export const directorState = {
  enabled: false,
  bootstrapped: false,
  targetSteamId: null,
  targetSinceMs: 0,
  lastSwitchMs:  0,
  eventBonuses:  new Map(),
  loopHandle:    null,
};

let directorTickInFlight = false;

// Throttle repeated skip-reason lines so the log isn't flooded at 4Hz.
// SWITCH lines always print.
let lastSkipMs = 0;
let lastSkipReason = "";
function logSkip(reason, extra = "") {
  const nowMs = Date.now();
  if (reason === lastSkipReason && nowMs - lastSkipMs < 10_000) return;
  lastSkipMs = nowMs;
  lastSkipReason = reason;
  process.stderr.write(`[director] ${reason}${extra ? ` ${extra}` : ""}\n`);
}

export async function directorTick() {
  if (!directorState.enabled || directorTickInFlight) return;
  directorTickInFlight = true;
  try {
    const nowMs = Date.now();
    detectEventsAndApplyBonuses(directorState.eventBonuses, nowMs);

    if (gsiState.players.size === 0) {
      logSkip("skip: no GSI players yet");
      return;
    }

    const pick = pickDirectorTarget(directorState.eventBonuses, directorState, nowMs);
    if (!pick || !pick.target) {
      logSkip("skip: no pickable target");
      return;
    }

    const cur = directorState.targetSteamId
      ? gsiState.players.get(directorState.targetSteamId)
      : null;
    if (cur && cur.steamId === pick.target.steamId && cur.alive) return;

    // Death of the current target cuts fast but NOT instantly — a short grace
    // (vs the full dwell) lets cs2's death-cam/PVS transition settle so we don't
    // cut into a black frame, and avoids whiplash on multi-kill exchanges. Event
    // bonuses (AWP kill, damage dealer, upset) already bumped priority — they wait
    // the full dwell.
    const sinceLast = nowMs - directorState.lastSwitchMs;
    const dwellFloor = pick.forcedByDeath ? DIRECTOR_DEATH_GRACE_MS : DIRECTOR_MIN_DWELL_MS;
    if (sinceLast < dwellFloor) {
      logSkip(
        "skip: min-dwell",
        `${sinceLast}ms < ${dwellFloor}ms (want=${pick.target.name ?? pick.target.steamId} slot=${pick.target.slot}${pick.forcedByDeath ? " death-grace" : ""})`,
      );
      return;
    }

    const reason = pick.forcedByDeath ? "death" : `prio=${pick.priority.toFixed(0)}`;
    process.stderr.write(
      `[director] SWITCH → ${pick.target.name ?? pick.target.steamId} slot=${pick.target.slot} ${reason}\n`,
    );
    const ok = await switchSpecTo(pick.target);
    if (!ok) {
      process.stderr.write(`[director] SWITCH FAILED slot=${pick.target.slot}\n`);
      return;
    }
    directorState.targetSteamId = pick.target.steamId;
    directorState.targetSinceMs = nowMs;
    directorState.lastSwitchMs  = nowMs;
    lastSkipReason = "";
  } finally {
    directorTickInFlight = false;
  }
}

export async function startDirector() {
  if (directorState.enabled) return;
  await sendKey(KEY_AUTODIRECTOR_OFF).catch(() => undefined);
  directorState.enabled       = true;
  directorState.targetSteamId = null;
  directorState.targetSinceMs = Date.now();
  directorState.lastSwitchMs  = 0;
  directorState.eventBonuses.clear();
  lastSkipMs = 0;
  lastSkipReason = "";
  directorState.loopHandle = setInterval(() => {
    void directorTick().catch(() => undefined);
  }, DIRECTOR_TICK_MS);
  process.stderr.write(
    `[director] ENABLED — gsi_players=${gsiState.players.size}\n`,
  );
}

export function stopDirector() {
  if (!directorState.enabled) return;
  directorState.enabled = false;
  if (directorState.loopHandle) {
    clearInterval(directorState.loopHandle);
    directorState.loopHandle = null;
  }
  process.stderr.write(`[director] DISABLED\n`);
}
