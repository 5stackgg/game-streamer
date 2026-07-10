import { readFileSync, statSync } from "node:fs";

import { DEMO_ROUND_TICKS_PATH, PLAYER_BINDINGS_PATH } from "../env.mjs";

export function loadPlayerBindings() {
  try {
    const parsed = JSON.parse(readFileSync(PLAYER_BINDINGS_PATH, "utf8"));
    return parsed?.accountid_to_key ?? {};
  } catch {
    return {};
  }
}

// mtime-keyed cache: the GSI reconciler calls this at ~10Hz, but the
// sidecar only changes when batch-highlights swaps demos.
let roundTicksCache = { key: null, value: [] };

export function loadRoundTicks() {
  try {
    const st = statSync(DEMO_ROUND_TICKS_PATH);
    const key = `${st.mtimeMs}:${st.size}`;
    if (roundTicksCache.key === key) {
      return roundTicksCache.value;
    }
    const raw = readFileSync(DEMO_ROUND_TICKS_PATH, "utf8").trim();
    const parsed = raw ? JSON.parse(raw) : [];
    roundTicksCache = { key, value: Array.isArray(parsed) ? parsed : [] };
    return roundTicksCache.value;
  } catch {
    return [];
  }
}
