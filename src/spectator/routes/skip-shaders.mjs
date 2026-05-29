import fs from "node:fs";
import path from "node:path";
import process from "node:process";

import { LOG_DIR } from "../env.mjs";
import { sendJson } from "../util/http.mjs";

// Operator "Skip shaders": drop the marker wait_for_cs2_process polls to
// dismiss the shader modal and launch cs2 now. Idempotent.
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
