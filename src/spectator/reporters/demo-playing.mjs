import process from "node:process";

import { execCfgCommand } from "../cs2/exec-cfg.mjs";
import {
  DEMO_SESSION_ID,
  DEMO_SESSION_TOKEN,
  STATUS_API_BASE,
} from "../env.mjs";
import { demoState } from "../state/demo.mjs";

export const playingState = {
  reported: false,
  // Set after the deferred demoui-hide keystroke lands. Surfaced in
  // /demo/state so batch-highlights doesn't capture the demoui panel.
  demouiHidden: false,
};

export function resetPlayingState() {
  playingState.reported = false;
  playingState.demouiHidden = false;
}

export async function reportDemoPlayingOnce() {
  if (playingState.reported) return;
  playingState.reported = true;

  void execCfgCommand("demo_pause").catch(() => undefined);
  // GSI lands AFTER the demoui panel renders; defer so the toggle
  // actually flips visible → hidden instead of no-op'ing pre-paint.
  // 500ms was tested and the demoui panel was still showing up in
  // captured clips — cs2 needs this full ~3s window between GSI's
  // first map-phase event and the panel being interactable.
  setTimeout(() => {
    void execCfgCommand("demoui")
      .catch(() => undefined)
      .finally(() => { playingState.demouiHidden = true; });
  }, 3000);

  demoState.paused         = true;
  demoState.lastTickAtSeek = 0;
  demoState.lastSeekRealMs = Date.now();

  if (!DEMO_SESSION_ID || !DEMO_SESSION_TOKEN || !STATUS_API_BASE) return;
  const url = `${STATUS_API_BASE}/demo-sessions/${DEMO_SESSION_ID}/status`;
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type":  "application/json",
        "x-origin-auth": `${DEMO_SESSION_ID}:${DEMO_SESSION_TOKEN}`,
      },
      body: JSON.stringify({ status: "playing" }),
      signal: AbortSignal.timeout(5_000),
    });
    if (!res.ok) {
      process.stderr.write(`[spec-server] status=playing POST ${res.status}\n`);
    }
  } catch (err) {
    process.stderr.write(
      `[spec-server] status=playing POST failed: ${(err && err.message) || err}\n`,
    );
  }
}
