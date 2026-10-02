import { spawn } from "node:child_process";
import process from "node:process";

import { PORT, SRC_DIR } from "../env.mjs";
import { findCs2Window } from "../cs2/window.mjs";
import { bumpActivity, demoState } from "../state/demo.mjs";
import { sendJson } from "../util/http.mjs";
import { filterOutroEnv } from "./outro-env.mjs";

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
  // pod is host-networked, so the POST body is UNTRUSTED. filterOutroEnv keeps
  // only CLIP_OUTRO_*/CLIP_BRAND_* keys, and all of them or none:
  //  - the URL-bearing keys must have the S3/MinIO origin the pod gets as
  //    S3_PUBLIC_ORIGIN (the origin the api's presigned URLs carry; DEMO_URL's
  //    origin for pods created before it existed), and be the URL as Node
  //    serializes it: curl, which fetches and uploads the cached outro, reads
  //    a backslash in the authority as userinfo and would connect to another
  //    host (see outro-env.mjs). Without this, an attacker could point the
  //    logo <Img src> (headless Chromium) or the curl GET/PUT at an arbitrary
  //    internal URL (SSRF) / host (arbitrary write).
  //  - CLIP_BRAND_ACCENT must be an HSL triple: the Outro puts it in its CSS
  //    as is, so anything else could make Chromium fetch a url() of the
  //    caller's choice.
  //  - the keys must form a complete hit (CLIP_OUTRO_URL) or render
  //    (CLIP_OUTRO_RENDER=1 with its PUT and logo URLs).
  // One rejected key drops the whole env, so the render falls back to the
  // baked stock outro rather than a half-branded one (the stock logo next to
  // the community's name and accent, and no cache fill).
  // Prefer the api-provided S3 presign origin (trusted pod env, independent of
  // the demo's source so faceit/external demos still brand); fall back to
  // DEMO_URL's origin for pods created before S3_PUBLIC_ORIGIN existed.
  let allowedOrigin = null;
  try {
    allowedOrigin = new URL(
      process.env.S3_PUBLIC_ORIGIN || process.env.DEMO_URL,
    ).origin;
  } catch {
    allowedOrigin = null;
  }
  const { env: outroEnv, dropped } = filterOutroEnv(
    body.outro_env,
    allowedOrigin,
  );
  if (dropped) {
    process.stderr.write(
      `[spec-server] render-clip: dropped outro env (${dropped}); outro falls back to baked\n`,
    );
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
