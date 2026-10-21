import process from "node:process";

import { HUD_HOST, HUD_PORT } from "../env.mjs";
import { gsiState } from "../state/gsi.mjs";

// JTs Hud's built-in `autoSwitchSides` setting was unreliable, so we
// own halftime/OT-half flips here: on each freezetime we compare the
// GSI-reported CT team to the previous freezetime's. A change means
// the in-game server already swapped sides, and the HUD's veto needs
// `reverse-side` to follow.
const sidesState = {
  lastCtTeamName: null,
  lastTTeamName:  null,
  lastMapName:    null,
  leftPlayers:    null,
  leftAtMs:       0,
};

// cs2 can post an update or two from the match a switch left. Teamless
// matches all name their lineups "Team 1" and "Team 2", so those updates are
// told apart by their players instead, until long after cs2 has left, which
// also covers two matches with the same players.
const SWITCH_SETTLE_MS = 20_000;

function currentMapName() {
  const raw = gsiState.mapName || "";
  return raw.includes("/") ? raw.substring(raw.lastIndexOf("/") + 1) : raw;
}

export function resetSidesState() {
  sidesState.lastCtTeamName = null;
  sidesState.lastTTeamName  = null;
  sidesState.lastMapName    = null;
  sidesState.leftPlayers    = null;
}

export function resetSidesForSwitch() {
  resetSidesState();
  sidesState.leftPlayers = new Set(gsiState.players.keys());
  sidesState.leftAtMs    = Date.now();
}

function fromLeftMatch() {
  const left = sidesState.leftPlayers;
  if (!left) {
    return false;
  }
  if (Date.now() - sidesState.leftAtMs < SWITCH_SETTLE_MS
      && [...gsiState.players.keys()].some((steamId) => left.has(steamId))) {
    return true;
  }
  sidesState.leftPlayers = null;
  return false;
}

export async function maybeReverseSideOnFreezetime() {
  const mapName = currentMapName();
  if (!mapName) return;
  // Warmup team names flicker; only act on real game phases.
  if (gsiState.mapPhase === "warmup") return;

  const ctName = gsiState.teamCtName;
  if (!ctName) return;
  const tName = gsiState.teamTName;
  if (fromLeftMatch()) {
    return;
  }

  // Map change → reseed the baseline without flipping. The HUD reseed
  // already restores starting sides for the new map.
  if (sidesState.lastMapName !== mapName) {
    sidesState.lastMapName    = mapName;
    sidesState.lastCtTeamName = ctName;
    sidesState.lastTTeamName  = tName;
    return;
  }

  const prev = sidesState.lastCtTeamName;
  const prevT = sidesState.lastTTeamName;
  sidesState.lastTTeamName = tName;
  if (prev === ctName) {
    return;
  }
  sidesState.lastCtTeamName = ctName;

  // A swap puts the team that was T on CT. Names that are new altogether are
  // another match, such as the one a switch moved to after a late update from
  // the one it left, so they only reseed.
  if (prevT !== null && ctName !== prevT) {
    process.stderr.write(
      `[spec-server] new teams on ${mapName} (CT ${prev} -> ${ctName}), not a side swap\n`,
    );
    return;
  }

  process.stderr.write(
    `[spec-server] side swap detected on ${mapName}: CT ${prev} -> ${ctName}, calling reverse-side\n`,
  );

  try {
    const r = await fetch(
      `http://${HUD_HOST}:${HUD_PORT}/api/match/current/veto/${encodeURIComponent(mapName)}/reverse-side`,
      { method: "PATCH", signal: AbortSignal.timeout(5_000) },
    );
    if (!r.ok) {
      const text = await r.text().catch(() => "");
      process.stderr.write(
        `[spec-server] reverse-side ${r.status}: ${text.slice(0, 200)}\n`,
      );
    }
  } catch (err) {
    process.stderr.write(
      `[spec-server] reverse-side failed: ${(err && err.message) || err}\n`,
    );
  }
}
