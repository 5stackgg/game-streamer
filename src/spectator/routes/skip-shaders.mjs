import fs from "node:fs";
import path from "node:path";
import process from "node:process";

import { LOG_DIR } from "../env.mjs";
import { sendJson } from "../util/http.mjs";

// Operator "Skip shaders": drop a marker file the bash launch loop
// (steam.sh wait_for_cs2_process) polls. When present it stops holding the
// launch open for the Vulkan shader compile and dismisses the "Processing
// Vulkan shaders" modal so cs2 starts immediately (shaders then compile
// on-demand → some in-game stutter until warm — the operator's tradeoff).
// Idempotent; harmless if shaders already finished (cs2 is already up).
export async function skipShadersHandler(_req, res) {
  const marker = path.join(LOG_DIR, "skip-shaders");
  try {
    fs.writeFileSync(marker, `${Date.now()}\n`);
  } catch (err) {
    sendJson(res, 500, {
      error: `could not write skip-shaders marker: ${err.message}`,
    });
    return;
  }
  process.stderr.write("[spec-server] skip-shaders requested\n");
  sendJson(res, 200, { ok: true });
}
