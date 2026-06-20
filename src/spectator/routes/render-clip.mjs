import { spawn } from "node:child_process";
import process from "node:process";

import { PORT, SRC_DIR } from "../env.mjs";
import { findCs2Window } from "../cs2/window.mjs";
import { bumpActivity, demoState } from "../state/demo.mjs";
import { sendJson } from "../util/http.mjs";

export async function renderClipHandler(_req, res, body) {
  const jobId   = String(body.job_id ?? "");
  const token   = String(body.token  ?? "");
  const apiBase = String(body.api_base ?? "");
  const rawDims = String(body.output_dims ?? "1920x1080");
  const outputDims = /^\d{2,4}x\d{2,4}$/.test(rawDims) ? rawDims : "1920x1080";
  const outputFps  = Number.parseInt(body.output_fps, 10) || 60;

  // Multi-segment editor sends `segments`; older callers send a single
  // start_tick/end_tick pair. Normalise to an array.
  let segments = Array.isArray(body.segments) ? body.segments : null;
  if (!segments && body.start_tick != null && body.end_tick != null) {
    segments = [{ start_tick: body.start_tick, end_tick: body.end_tick }];
  }
  const cleaned = (segments ?? [])
    .map((s) => {
      const killTick = Number.parseInt(s?.kill_tick ?? s?.event_tick, 10);
      return {
        start_tick: Number.parseInt(s?.start_tick, 10),
        end_tick:   Number.parseInt(s?.end_tick,   10),
        pov_steam_id: typeof s?.pov_steam_id === "string" ? s.pov_steam_id : null,
        ...(Number.isFinite(killTick) ? { kill_tick: killTick } : {}),
      };
    })
    .filter((s) =>
      Number.isFinite(s.start_tick) &&
      Number.isFinite(s.end_tick) &&
      s.end_tick > s.start_tick,
    );

  if (!jobId || !token || !apiBase || cleaned.length === 0) {
    sendJson(res, 400, {
      error: "job_id, token, api_base, and at least one valid segment required",
    });
    return;
  }
  if (!(await findCs2Window())) {
    sendJson(res, 503, { error: "cs2 not running" });
    return;
  }

  // Outro/branding env from the api. This endpoint is unauthenticated and the
  // pod is host-networked, so the POST body is UNTRUSTED. Two gates:
  //  1. key allowlist — only CLIP_OUTRO_*/CLIP_BRAND_* may reach the render env.
  //  2. URL-value allowlist — the URL-bearing keys must share the S3/MinIO origin
  //     the api presigns against (taken from DEMO_URL). Without this, an attacker
  //     could point the logo <Img src> (headless Chromium) or the curl PUT at an
  //     arbitrary internal URL (SSRF) / host (arbitrary write). A rejected URL key
  //     is dropped → the render falls back to the baked stock outro.
  const URL_KEYS = new Set([
    "CLIP_OUTRO_URL",
    "CLIP_OUTRO_PUT_URL",
    "CLIP_BRAND_LOGO_URL",
  ]);
  let allowedOrigin = null;
  try {
    allowedOrigin = new URL(process.env.DEMO_URL).origin;
  } catch {
    allowedOrigin = null;
  }
  const outroEnv = {};
  const outroSrc =
    body.outro_env && typeof body.outro_env === "object" ? body.outro_env : {};
  for (const [k, v] of Object.entries(outroSrc)) {
    if (!(k.startsWith("CLIP_OUTRO_") || k.startsWith("CLIP_BRAND_")) || v == null) {
      continue;
    }
    if (URL_KEYS.has(k)) {
      let sameOrigin = false;
      try {
        sameOrigin =
          !!allowedOrigin && new URL(String(v)).origin === allowedOrigin;
      } catch {
        sameOrigin = false;
      }
      if (!sameOrigin) {
        process.stderr.write(
          `[spec-server] render-clip: rejected ${k} (not the S3 origin) — outro falls back to baked\n`,
        );
        continue;
      }
    }
    outroEnv[k] = String(v);
  }

  const child = spawn("bash", [`${SRC_DIR}/lib/inline-clip-render.sh`], {
    detached: true,
    stdio: ["ignore", "inherit", "inherit"],
    env: {
      ...process.env,
      CLIP_RENDER_JOB_ID: jobId,
      CLIP_RENDER_TOKEN:  token,
      STATUS_API_BASE:    apiBase,
      CLIP_SEGMENTS:      JSON.stringify(cleaned),
      CLIP_OUTPUT_DIMS:   outputDims,
      CLIP_OUTPUT_FPS:    String(outputFps),
      CLIP_TICK_RATE:     String(demoState.tickRate || 64),
      SPEC_SERVER_URL:    `http://127.0.0.1:${PORT}`,
      ...outroEnv,
    },
  });
  child.unref();
  bumpActivity();
  sendJson(res, 202, { ok: true, job_id: jobId, pid: child.pid });
  const totalTicks = cleaned.reduce((acc, s) => acc + (s.end_tick - s.start_tick), 0);
  process.stderr.write(
    `[spec-server] render-clip job=${jobId} pid=${child.pid} segments=${cleaned.length} ticks=${totalTicks}\n`,
  );
}
