import process from "node:process";

import { DEMO_SESSION_ID, STATUS_API_BASE } from "../env.mjs";
import { demoState } from "../state/demo.mjs";
import { gsiState } from "../state/gsi.mjs";
import { buildDemoState } from "../routes/demo-state.mjs";

// Pushes the /demo/state snapshot to the api, which fans it out to the
// session's watchers. The web's poll is a fallback that only fires when
// pushes go quiet, so an old pod image degrades to polling on its own.
const PUSH_INTERVAL_MS = 1_000;
// Paused demos are static — drop to a keepalive unless something changed.
const PAUSED_KEEPALIVE_MS = 5_000;
// Floor between pushes so a burst of control-triggered ones coalesces.
const MIN_PUSH_GAP_MS = 250;

let lastPushMs = 0;
let lastFingerprint = "";
let pushTimer = null;
let inFlight = false;

function gsiFresh() {
  return (
    gsiState.lastReceivedMs > 0 &&
    Date.now() - gsiState.lastReceivedMs < 30_000
  );
}

// Change detection for the paused path — excludes the always-advancing
// tick/timing fields.
function fingerprintOf(state) {
  return JSON.stringify({
    paused: state.paused,
    seeking: state.seeking,
    rate: state.rate,
    gsi: state.gsi
      ? {
          spectated: state.gsi.spectated_steam_id,
          slots: state.gsi.spec_slots,
          ct: state.gsi.team_ct_score,
          t: state.gsi.team_t_score,
          phase: state.gsi.round_phase,
          round: state.gsi.round_number,
        }
      : null,
  });
}

async function pushOnce() {
  if (inFlight) return;
  inFlight = true;
  try {
    const state = buildDemoState({ demoLoaded: true });
    lastPushMs = Date.now();
    lastFingerprint = fingerprintOf(state);
    const res = await fetch(
      `${STATUS_API_BASE}/demo-sessions/${DEMO_SESSION_ID}/state`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(state),
        signal: AbortSignal.timeout(3_000),
      },
    );
    if (!res.ok && res.status !== 404) {
      throttledWarn(`state push -> ${res.status}`);
    }
  } catch (err) {
    throttledWarn(`state push failed: ${(err && err.message) || err}`);
  } finally {
    inFlight = false;
  }
}

let lastWarnMs = 0;
function throttledWarn(msg) {
  const now = Date.now();
  if (now - lastWarnMs < 30_000) return;
  lastWarnMs = now;
  process.stderr.write(`[spec-server] ${msg}\n`);
}

function tick() {
  if (!gsiFresh()) return;
  if (Date.now() - lastPushMs < MIN_PUSH_GAP_MS) return;
  if (demoState.paused && demoState.seekTargetTick === null) {
    const unchanged =
      fingerprintOf(buildDemoState({ demoLoaded: true })) === lastFingerprint;
    if (unchanged && Date.now() - lastPushMs < PAUSED_KEEPALIVE_MS) return;
  }
  void pushOnce();
}

export function pushStateSoon() {
  if (!DEMO_SESSION_ID || !STATUS_API_BASE) return;
  if (!gsiFresh()) return;
  const wait = Math.max(0, MIN_PUSH_GAP_MS - (Date.now() - lastPushMs));
  setTimeout(() => void pushOnce(), wait);
}

export function startStatePush() {
  if (pushTimer || !DEMO_SESSION_ID || !STATUS_API_BASE) return;
  pushTimer = setInterval(tick, PUSH_INTERVAL_MS);
  process.stderr.write("[spec-server] state push reporter started\n");
}
