import process from "node:process";

import { readJsonBody, sendJson } from "../util/http.mjs";

import { healthHandler } from "./health.mjs";
import { demoStateHandler } from "./demo-state.mjs";
import { gsiHandler } from "./gsi.mjs";
import {
  autodirectorHandler,
  clickHandler,
  hudHandler,
  hudModeHandler,
  jumpHandler,
  playerHandler,
  slotHandler,
  specScoreboardHandler,
  specXrayHandler,
} from "./spec.mjs";
import {
  demouiHandler,
  execHandler,
  pauseHandler,
  reloadHandler,
  resumeHandler,
  roundHandler,
  seekHandler,
  skipHandler,
  speedHandler,
  toggleHandler,
  xrayHandler,
} from "./demo.mjs";
import { renderClipHandler } from "./render-clip.mjs";
import { switchMatchHandler } from "./switch-match.mjs";
import { reconnectHandler } from "./reconnect.mjs";

const HEALTH_GET_URLS = new Set(["/", "/health", "/spec/health"]);

const ROUTES = new Map([
  ["GET /demo/state", demoStateHandler],
  ["POST /gsi", gsiHandler],

  ["POST /spec/click",        clickHandler],
  ["POST /spec/jump",         jumpHandler],
  ["POST /spec/player",       playerHandler],
  ["POST /spec/slot",         slotHandler],
  ["POST /spec/autodirector", autodirectorHandler],
  ["POST /spec/hud",          hudHandler],
  ["POST /spec/hud-mode",     hudModeHandler],
  ["POST /spec/switch-match", switchMatchHandler],
  ["POST /spec/reconnect",    reconnectHandler],
  ["POST /spec/xray",         specXrayHandler],
  ["POST /spec/scoreboard",   specScoreboardHandler],

  ["POST /demo/toggle",      toggleHandler],
  ["POST /demo/pause",       pauseHandler],
  ["POST /demo/resume",      resumeHandler],
  ["POST /demo/seek",        seekHandler],
  ["POST /demo/skip",        skipHandler],
  ["POST /demo/speed",       speedHandler],
  ["POST /demo/reload",      reloadHandler],
  ["POST /demo/xray",        xrayHandler],
  ["POST /demo/demoui",      demouiHandler],
  ["POST /demo/round",       roundHandler],
  ["POST /demo/exec",        execHandler],
  ["POST /demo/render-clip", renderClipHandler],
]);

export async function dispatch(req, res) {
  const method = req.method ?? "GET";
  const url    = req.url ?? "/";

  try {
    if (method === "OPTIONS") { sendJson(res, 204, {}); return; }

    if (method === "GET" && HEALTH_GET_URLS.has(url)) {
      await healthHandler(req, res, {});
      logResponse(method, url, res);
      return;
    }

    const handler = ROUTES.get(`${method} ${url}`);
    if (!handler) {
      sendJson(res, 404, { error: "not found" });
      logResponse(method, url, res);
      return;
    }

    let body = {};
    if (method !== "GET") {
      try { body = await readJsonBody(req); }
      catch {
        sendJson(res, 400, { error: "invalid json" });
        logResponse(method, url, res);
        return;
      }
    }
    await handler(req, res, body);
    logResponse(method, url, res);
  } catch (err) {
    process.stderr.write(`[spec-server] handler threw ${(err && err.stack) || err}\n`);
    if (!res.headersSent) sendJson(res, 500, { error: "internal" });
  }
}

// Both endpoints are polled at high frequency by upstream consumers
// (gsi: cs2 @10Hz, demo/state: web scrubber @1Hz). Their handlers log
// state transitions themselves; per-request lines just drown the log.
const QUIET_URLS = new Set(["/gsi", "/demo/state"]);

function logResponse(method, url, res) {
  if (QUIET_URLS.has(url)) return;
  process.stderr.write(`[spec-server] ${method} ${url} -> ${res.statusCode}\n`);
}
