#!/usr/bin/env node
// Tiny HTTP control daemon for cs2 spectator actions.
//
// Exposes the small set of inputs an operator (or the 5stack web UI)
// needs to drive a spectator slot inside the headless game-streamer
// container — without giving anyone a full remote desktop. All actions
// are routed via xdotool against the live cs2 window on $DISPLAY.
//
// Routes (all POST, JSON body):
//
//   /spec/click          {"button": "left"|"right"}
//       left = next observer target, right = previous.
//
//   /spec/jump           (no body)
//       Toggles between locked-on a player and free-roam.
//
//   /spec/player         {"accountid": <number>}
//       Switch directly to the spectator target with this accountid
//       (32-bit Steam ID — steamid64 minus 76561197960265728).
//
//   /spec/slot           {"slot": 1..12}
//       Switch by spectator-slot number using cs2's default digit
//       binds (1..9, 0, minus, equal — set by resources/observer.cfg).
//
//   /spec/autodirector   {"enabled": true|false}
//       true  -> spec_autodirector 1; spec_mode 5  (cinematic auto-cam)
//       false -> spec_autodirector 0               (operator drives)
//
// Demo-playback routes (only meaningful when run-demo.sh launched cs2):
//
//   /demo/toggle               demo_togglepause (cs2-bound key)
//   /demo/pause                idempotent — only fires the toggle if currently playing
//   /demo/resume               idempotent — only fires the toggle if currently paused
//   /demo/seek    {"tick": n}  demo_gototick n  (typed into dev console)
//   /demo/skip    {"secs": n}  shifts current estimate by n seconds (negative ok)
//   /demo/speed   {"rate": n}  host_timescale n; uses bound F-keys for the
//                              presets {0.25,0.5,1,2,4} and typed console
//                              commands for arbitrary values
//   /demo/round   {"round": n} demo_gototick <round_n_start_tick>; tick map
//                              comes from $LOG_DIR/demo-round-ticks.json
//                              (written by run-demo.sh from $ROUND_TICKS)
//   GET /demo/state            best-effort {tick, paused, rate, total_ticks,
//                              tick_rate, last_activity_ms_ago} for the api's
//                              idle-reaper + the web scrubber's animation
//
// How it works (and why it isn't xdotool-typing the dev console):
//
// The OpenHud overlay is raised above cs2 in the X stack so ximagesrc
// captures cs2 + HUD composited together. If we ever `windowactivate`
// cs2 to make it the keystroke target — the obvious naive way — Openbox
// restacks cs2 above the overlay, and on this WM can outright destroy
// the overlay window (the "Overlay" button in the OpenHud admin UI then
// has to recreate it). With the operator switching players many times
// per round, that's catastrophic.
//
// Instead, every action above is pre-bound to a dedicated key in cs2's
// autoexec.cfg (written by run-live.sh from the match metadata) and
// the OpenHud overlay BrowserWindow is built with `focusable: false`
// (see the sed step in openhud/Dockerfile). Because the overlay can
// never take keyboard focus, cs2 holds focus continuously from the
// moment it launches — even though the overlay is stacked above it
// for compositing. We deliver the key with plain `xdotool key` (XTest)
// which goes to the focused window, i.e. cs2. No windowactivate, no
// windowfocus, no restacking, no flicker, no Electron alpha loss.
//
// Static binds (mirror the lines in lib/openhud.sh:spec_static_binds_block):
//   F1 = spec_next        (/spec/click button=left)
//   F2 = spec_prev        (/spec/click button=right)
//   F3 = +jump            (/spec/jump)
//   F4 = autodirector ON  (/spec/autodirector enabled=true)
//   F5 = autodirector OFF (/spec/autodirector enabled=false)
//   F6-F12 = per-player slots, written by write_spec_player_binds
//            from the seeded match metadata (up to 7 lineup players).
//
// /spec/slot uses the digit binds set up by resources/observer.cfg
// (spec_player_<n> slot binds), which are also in cs2 directly — so it
// only needs windowfocus + key, no autoexec changes.
//
// Why a separate daemon (not in OpenHud's Express): OpenHud is the HUD
// app — keeping cs2 input control out of it preserves the boundary and
// keeps blast radius small if either side has a bug. The daemon is
// tiny, stdlib-only (Node http + child_process), no deps to manage.
//
// Started by src/flows/setup-steam.sh after Xorg comes up. Logs to
// $LOG_DIR/spec-server.log via redirect from the start command.

import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import process from "node:process";

const DISPLAY = process.env.DISPLAY ?? ":0";
const PORT = parseInt(process.env.SPEC_PORT ?? "1350", 10);
const BIND = process.env.SPEC_BIND ?? "0.0.0.0";

// Static action -> cs2-bound F-key. Mirror of the binds written by
// run-live.sh into autoexec.cfg via lib/openhud.sh:spec_static_binds_block.
// If you change a key here, change it there (and vice versa).
const KEY_SPEC_NEXT = "F1";
const KEY_SPEC_PREV = "F2";
const KEY_SPEC_JUMP = "F3";
const KEY_AUTODIRECTOR_ON = "F4";
const KEY_AUTODIRECTOR_OFF = "F5";

// Demo-playback bound keys (run-demo.sh + lib/openhud.sh:demo_static_binds_block).
const KEY_DEMO_TOGGLE = "Pause";
const KEY_DEMO_SKIP_BACK = "Home";    // bound to demo_gototick -960 (~ -15s)
const KEY_DEMO_SKIP_FWD  = "End";     // bound to demo_gototick +960 (~ +15s)
const SPEED_KEY_BY_RATE = {
  "0.25": "Next",        // PageDown
  "0.5":  "semicolon",
  "1":    "Insert",
  "2":    "apostrophe",
  "4":    "Prior",       // PageUp
};

// Sidecar JSON dropped by run-demo.sh so /demo/round can resolve a
// round number to a tick without a round-trip back to the api.
const DEMO_ROUND_TICKS_PATH =
  process.env.DEMO_ROUND_TICKS_PATH ??
  path.join(process.env.LOG_DIR ?? "/tmp/game-streamer", "demo-round-ticks.json");

// Demo session bookkeeping for tick estimation + idle-timeout. Held in
// memory for the life of the daemon (which is the life of the pod).
const demoState = {
  // Best-effort: tick at the moment of the most recent /demo/seek (or
  // session start). Combined with `lastSeekRealMs` and `rate` lets us
  // give the api a coarse current-tick estimate so the scrubber can
  // animate without polling cs2's console.
  lastTickAtSeek: 0,
  lastSeekRealMs: Date.now(),
  rate: 1,
  paused: false,
  totalTicks: parseInt(process.env.DEMO_TOTAL_TICKS ?? "0", 10) || 0,
  tickRate: parseFloat(process.env.DEMO_TICK_RATE ?? "64") || 64,
  // Bumped on every /demo/* POST. The api's idle reaper compares this
  // against `now()` to decide whether to tear the pod down.
  lastActivityMs: Date.now(),
};
function bumpActivity() { demoState.lastActivityMs = Date.now(); }
function estimateCurrentTick() {
  if (demoState.paused) return demoState.lastTickAtSeek;
  const elapsedSec = (Date.now() - demoState.lastSeekRealMs) / 1000;
  return Math.max(
    0,
    Math.round(demoState.lastTickAtSeek + elapsedSec * demoState.rate * demoState.tickRate),
  );
}

// Where run-live.sh drops the accountid -> F-key map after seeding the
// OpenHud DB. Read fresh per request so an operator can rerun the seed
// step mid-stream without restarting this daemon.
const PLAYER_BINDINGS_PATH =
  process.env.SPEC_BINDINGS_PATH ??
  path.join(process.env.LOG_DIR ?? "/tmp/game-streamer", "spec-bindings.json");

/**
 * Run a subcommand with a forced $DISPLAY, capture stdout/stderr.
 * @param {string[]} args
 * @param {{ timeoutMs?: number }} [opts]
 * @returns {Promise<{ code: number | null; stdout: string; stderr: string }>}
 */
function run(args, { timeoutMs = 5000 } = {}) {
  return new Promise((resolve) => {
    const child = spawn(args[0], args.slice(1), {
      env: { ...process.env, DISPLAY },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const stdoutChunks = [];
    const stderrChunks = [];
    let timer = setTimeout(() => {
      child.kill("SIGKILL");
    }, timeoutMs);
    child.stdout.on("data", (c) => stdoutChunks.push(c));
    child.stderr.on("data", (c) => stderrChunks.push(c));
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({
        code,
        stdout: Buffer.concat(stdoutChunks).toString("utf8"),
        stderr: Buffer.concat(stderrChunks).toString("utf8"),
      });
    });
    child.on("error", () => {
      clearTimeout(timer);
      resolve({ code: -1, stdout: "", stderr: "" });
    });
  });
}

/**
 * Find the cs2 window on $DISPLAY. Tries several strategies because
 * cs2's reported window name varies by game state (menu vs spectator
 * vs demo playback) and xdotool's --name is matched per-property:
 * if WM_NAME differs from _NET_WM_NAME the anchored ^...$ form misses.
 *
 * @returns {Promise<string | null>}
 */
async function findCs2Window() {
  for (const pattern of ["Counter-Strike 2", "Counter-Strike", "cs2"]) {
    const r = await run(["xdotool", "search", "--name", pattern]);
    if (r.code === 0) {
      const ids = r.stdout.trim().split("\n").filter(Boolean);
      if (ids.length) return ids[0];
    }
  }
  const byClass = await run(["xdotool", "search", "--class", "cs2"]);
  if (byClass.code === 0) {
    const ids = byClass.stdout.trim().split("\n").filter(Boolean);
    if (ids.length) return ids[0];
  }
  const tree = await run([
    "xwininfo",
    "-display",
    DISPLAY,
    "-root",
    "-tree",
  ]);
  if (tree.code === 0) {
    for (const line of tree.stdout.split("\n")) {
      if (line.includes('"Counter-Strike 2"')) {
        const id = line.trim().split(/\s+/)[0];
        if (id?.startsWith("0x")) return id;
      }
    }
  }
  process.stderr.write(
    `spec-server: findCs2Window(): no match on DISPLAY=${DISPLAY}\n`,
  );
  const diag = await run(["xdotool", "search", "--name", ".+"]);
  if (diag.code === 0) {
    const names = diag.stdout.trim().split("\n").slice(0, 20);
    process.stderr.write(
      `spec-server: visible window ids on display: ${JSON.stringify(names)}\n`,
    );
  }
  return null;
}

/**
 * Deliver a single keypress to cs2.
 *
 * cs2 holds keyboard focus continuously: the OpenHud overlay
 * BrowserWindow is built with `focusable: false` (see the sed step in
 * openhud/Dockerfile), so even though it's stacked above cs2 it can
 * never receive focus. That means `xdotool key` (XTest, no --window,
 * no focus juggling) goes straight to cs2.
 *
 * Why not XSendEvent (`--window`)? cs2 filters synthetic events, so
 * keys delivered that way are dropped on the floor. Verified against
 * a live cs2 spec session — F-keys from `xdotool key --window <wid>`
 * never fire the bound command.
 *
 * Why not windowfocus/windowactivate? Both cause Electron's
 * transparent overlay to lose its alpha channel (well-known Linux
 * Electron behavior on focus-loss), and windowactivate additionally
 * restacks cs2 on top of the overlay. With the overlay marked
 * non-focusable upstream, neither is ever needed — focus stays on
 * cs2 from launch, the overlay stays composited above.
 *
 * @param {string} key  X11 keysym name (e.g. "F1", "1", "minus")
 * @returns {Promise<boolean>}
 */
async function sendKey(key) {
  if ((await findCs2Window()) === null) return false;
  await run(["xdotool", "key", "--clearmodifiers", key]);
  return true;
}

/**
 * Open cs2's dev console, type a command, hit Return, close the console.
 *
 * Used for demo controls that take a runtime parameter (`demo_gototick
 * <tick>`, arbitrary `host_timescale <rate>`) — these can't be pre-bound
 * to a single F-key the way pause/speed-presets are.
 *
 * Why this is safe even with the OpenHud overlay raised: cs2 holds
 * keyboard focus continuously (overlay is `focusable: false`), so the
 * `xdotool key`/`xdotool type` calls — which target the focused window
 * via XTest — go straight to cs2 without needing windowactivate. The
 * windowactivate path used by lib/xorg.sh:cs2_console_command is only
 * needed when called interactively from a debug shell where cs2 may
 * have lost focus; here we never lose it.
 *
 * @param {string} cmd
 * @returns {Promise<boolean>}
 */
async function sendConsoleCommand(cmd) {
  if ((await findCs2Window()) === null) return false;
  await run(["xdotool", "key", "--clearmodifiers", "grave"]);
  await new Promise((r) => setTimeout(r, 80));
  await run(["xdotool", "type", "--delay", "20", cmd]);
  await new Promise((r) => setTimeout(r, 40));
  await run(["xdotool", "key", "--clearmodifiers", "Return"]);
  await new Promise((r) => setTimeout(r, 60));
  await run(["xdotool", "key", "--clearmodifiers", "grave"]);
  return true;
}

/**
 * Read the round_ticks sidecar (written by run-demo.sh from $ROUND_TICKS).
 * @returns {Array<{round: number, start_tick: number, end_tick: number}>}
 */
function loadRoundTicks() {
  try {
    const raw = readFileSync(DEMO_ROUND_TICKS_PATH, "utf8").trim();
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

/**
 * Read the accountid -> keysym map written by run-live.sh after the
 * match-metadata seed. Returns an empty map if the file is missing or
 * malformed; callers treat that as "no per-player binds available"
 * and 404 the request.
 * @returns {Record<string, string>}
 */
function loadPlayerBindings() {
  try {
    const raw = readFileSync(PLAYER_BINDINGS_PATH, "utf8");
    const parsed = JSON.parse(raw);
    return parsed?.accountid_to_key ?? {};
  } catch {
    return {};
  }
}

const CORS_HEADERS = {
  // Permissive CORS — the daemon is firewalled by the K8s Service /
  // Ingress that fronts it, not at the application layer.
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function sendJson(res, code, obj) {
  const body = Buffer.from(JSON.stringify(obj));
  res.writeHead(code, {
    "Content-Type": "application/json",
    "Content-Length": String(body.length),
    ...CORS_HEADERS,
  });
  res.end(body);
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch {
        reject(new Error("invalid json"));
      }
    });
    req.on("error", reject);
  });
}

const server = createServer(async (req, res) => {
  const method = req.method ?? "GET";
  const url = req.url ?? "/";
  const log = (line) => {
    process.stdout.write(`[spec-server] ${method} ${url} ${line}\n`);
  };

  try {
    if (method === "OPTIONS") {
      sendJson(res, 204, {});
      return;
    }

    if (method === "GET" && (url === "/" || url === "/health" || url === "/spec/health")) {
      const wid = await findCs2Window();
      const bindings = loadPlayerBindings();
      sendJson(res, 200, {
        ok: true,
        display: DISPLAY,
        cs2_window: wid,
        cs2_running: wid !== null,
        player_bindings: Object.keys(bindings).length,
      });
      log(`-> 200 (cs2_running=${wid !== null}, player_bindings=${Object.keys(bindings).length})`);
      return;
    }

    if (method === "GET" && url === "/demo/state") {
      sendJson(res, 200, {
        tick: estimateCurrentTick(),
        total_ticks: demoState.totalTicks,
        tick_rate: demoState.tickRate,
        rate: demoState.rate,
        paused: demoState.paused,
        last_activity_ms_ago: Date.now() - demoState.lastActivityMs,
      });
      return;
    }

    if (method !== "POST") {
      sendJson(res, 404, { error: "not found" });
      log("-> 404");
      return;
    }

    let body;
    try {
      body = await readJsonBody(req);
    } catch {
      sendJson(res, 400, { error: "invalid json" });
      log("-> 400 invalid json");
      return;
    }

    if (url === "/spec/click") {
      const key = body.button === "right" ? KEY_SPEC_PREV : KEY_SPEC_NEXT;
      const ok = await sendKey(key);
      sendJson(res, ok ? 200 : 503, ok ? { ok, key } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} click (${key})`);
      return;
    }

    if (url === "/spec/jump") {
      const ok = await sendKey(KEY_SPEC_JUMP);
      sendJson(res, ok ? 200 : 503, ok ? { ok, key: KEY_SPEC_JUMP } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} jump`);
      return;
    }

    if (url === "/spec/player") {
      const aidInt = Number.parseInt(body.accountid, 10);
      if (!Number.isFinite(aidInt)) {
        sendJson(res, 400, { error: "accountid (int) required" });
        log("-> 400 bad accountid");
        return;
      }
      const key = loadPlayerBindings()[String(aidInt)];
      if (!key) {
        sendJson(res, 404, {
          error: `no key bound for accountid ${aidInt}`,
          hint: "rerun match-metadata seed so per-player binds get written",
        });
        log(`-> 404 player ${aidInt} (not in bindings map)`);
        return;
      }
      const ok = await sendKey(key);
      sendJson(res, ok ? 200 : 503, { ok, accountid: aidInt, key });
      log(`-> ${ok ? 200 : 503} player ${aidInt} (${key})`);
      return;
    }

    if (url === "/spec/slot") {
      const slotInt = Number.parseInt(body.slot, 10);
      if (!Number.isFinite(slotInt)) {
        sendJson(res, 400, { error: "slot (int 1..12) required" });
        log("-> 400 bad slot");
        return;
      }
      if (slotInt < 1 || slotInt > 12) {
        sendJson(res, 400, { error: "slot must be 1..12" });
        log("-> 400 slot out of range");
        return;
      }
      // CS2's default spec keybinds: number row keys map directly to
      // slots. xdotool key names: digits are "1".."9","0", and the
      // bindings in resources/observer.cfg use "minus" and "equal" for
      // 11/12.
      const SLOT_KEYS = [
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "minus", "equal",
      ];
      const key = SLOT_KEYS[slotInt - 1];
      const ok = await sendKey(key);
      sendJson(res, ok ? 200 : 503, ok ? { ok, slot: slotInt, key } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} slot ${slotInt} (key ${key})`);
      return;
    }

    if (url === "/spec/autodirector") {
      const enabled = Boolean(body.enabled);
      const key = enabled ? KEY_AUTODIRECTOR_ON : KEY_AUTODIRECTOR_OFF;
      const ok = await sendKey(key);
      sendJson(res, ok ? 200 : 503, ok ? { ok, enabled, key } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} autodirector ${enabled} (${key})`);
      return;
    }

    // ---- /demo/* — demo-playback controls ----
    // Most run on cs2 console commands rather than F-key binds because
    // they take parameters (tick, rate). Pause/speed-presets have F-key
    // binds and use the safe sendKey path.

    if (url === "/demo/toggle") {
      const ok = await sendKey(KEY_DEMO_TOGGLE);
      if (ok) {
        demoState.paused = !demoState.paused;
        // Snapshot the current estimated tick at the moment we paused
        // so resume picks up from the right place.
        if (demoState.paused) demoState.lastTickAtSeek = estimateCurrentTick();
        demoState.lastSeekRealMs = Date.now();
        bumpActivity();
      }
      sendJson(res, ok ? 200 : 503, ok ? { ok, paused: demoState.paused } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} demo/toggle (paused=${demoState.paused})`);
      return;
    }

    if (url === "/demo/pause") {
      // Idempotent — only send the key if we believe we're playing.
      // Accidentally double-toggling would actually unpause.
      let ok = true;
      if (!demoState.paused) {
        ok = await sendKey(KEY_DEMO_TOGGLE);
        if (ok) {
          demoState.lastTickAtSeek = estimateCurrentTick();
          demoState.paused = true;
          demoState.lastSeekRealMs = Date.now();
        }
      }
      bumpActivity();
      sendJson(res, ok ? 200 : 503, ok ? { ok, paused: true } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} demo/pause`);
      return;
    }

    if (url === "/demo/resume") {
      let ok = true;
      if (demoState.paused) {
        ok = await sendKey(KEY_DEMO_TOGGLE);
        if (ok) {
          demoState.paused = false;
          demoState.lastSeekRealMs = Date.now();
        }
      }
      bumpActivity();
      sendJson(res, ok ? 200 : 503, ok ? { ok, paused: false } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} demo/resume`);
      return;
    }

    if (url === "/demo/seek") {
      const tick = Number.parseInt(body.tick, 10);
      if (!Number.isFinite(tick) || tick < 0) {
        sendJson(res, 400, { error: "tick (non-negative int) required" });
        log("-> 400 demo/seek bad tick");
        return;
      }
      const ok = await sendConsoleCommand(`demo_gototick ${tick}`);
      if (ok) {
        demoState.lastTickAtSeek = tick;
        demoState.lastSeekRealMs = Date.now();
        bumpActivity();
      }
      sendJson(res, ok ? 200 : 503, ok ? { ok, tick } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} demo/seek tick=${tick}`);
      return;
    }

    if (url === "/demo/skip") {
      const secs = Number.parseFloat(body.secs);
      if (!Number.isFinite(secs)) {
        sendJson(res, 400, { error: "secs (number) required" });
        log("-> 400 demo/skip bad secs");
        return;
      }
      // Bound keys for ±15s, the operator-friendly defaults. Anything
      // else falls back to typed console (rare / debug).
      let ok;
      let via;
      if (secs === -15 || secs === 15) {
        const key = secs < 0 ? KEY_DEMO_SKIP_BACK : KEY_DEMO_SKIP_FWD;
        ok = await sendKey(key);
        via = `key:${key}`;
      } else {
        const target = Math.max(
          0,
          estimateCurrentTick() + Math.round(secs * demoState.tickRate),
        );
        ok = await sendConsoleCommand(`demo_gototick ${target}`);
        via = "console";
      }
      if (ok) {
        // Estimator drift: bump tick by approximation. Real tick will
        // resync on next /demo/state poll.
        demoState.lastTickAtSeek = Math.max(
          0,
          estimateCurrentTick() + Math.round(secs * demoState.tickRate),
        );
        demoState.lastSeekRealMs = Date.now();
        bumpActivity();
      }
      sendJson(res, ok ? 200 : 503, ok ? { ok, secs, via } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} demo/skip secs=${secs} (${via})`);
      return;
    }

    if (url === "/demo/speed") {
      const rate = Number.parseFloat(body.rate);
      if (!Number.isFinite(rate) || rate <= 0) {
        sendJson(res, 400, { error: "rate (positive number) required" });
        log("-> 400 demo/speed bad rate");
        return;
      }
      // Clamp aggressively — host_timescale beyond 8 destabilises cs2's
      // physics tick + audio sync, and below 0.1 is indistinguishable
      // from a near-pause for the operator.
      const clamped = Math.min(8, Math.max(0.1, rate));
      // Snapshot tick BEFORE changing rate so the estimator stays
      // continuous across the transition.
      demoState.lastTickAtSeek = estimateCurrentTick();
      demoState.lastSeekRealMs = Date.now();
      // Prefer the bound F-key for a known preset (no console flash);
      // fall back to typed `host_timescale <rate>` for arbitrary values.
      const presetKey = SPEED_KEY_BY_RATE[String(clamped)];
      const ok = presetKey
        ? await sendKey(presetKey)
        : await sendConsoleCommand(`host_timescale ${clamped}`);
      if (ok) {
        demoState.rate = clamped;
        bumpActivity();
      }
      sendJson(
        res,
        ok ? 200 : 503,
        ok ? { ok, rate: clamped, via: presetKey ? "key" : "console" } : { error: "cs2 not running" },
      );
      log(`-> ${ok ? 200 : 503} demo/speed rate=${clamped} (${presetKey ? "key" : "console"})`);
      return;
    }

    if (url === "/demo/round") {
      const round = Number.parseInt(body.round, 10);
      if (!Number.isFinite(round) || round < 1) {
        sendJson(res, 400, { error: "round (int >= 1) required" });
        log("-> 400 demo/round bad round");
        return;
      }
      const map = loadRoundTicks();
      const entry = map.find((r) => r.round === round);
      if (!entry) {
        sendJson(res, 404, {
          error: `no tick mapping for round ${round}`,
          hint: "demo metadata not parsed yet — try again in a few seconds",
        });
        log(`-> 404 demo/round ${round} (not in ticks map; have ${map.length})`);
        return;
      }
      const ok = await sendConsoleCommand(`demo_gototick ${entry.start_tick}`);
      if (ok) {
        demoState.lastTickAtSeek = entry.start_tick;
        demoState.lastSeekRealMs = Date.now();
        bumpActivity();
      }
      sendJson(res, ok ? 200 : 503, ok ? { ok, round, tick: entry.start_tick } : { error: "cs2 not running" });
      log(`-> ${ok ? 200 : 503} demo/round ${round} -> tick ${entry.start_tick}`);
      return;
    }

    sendJson(res, 404, { error: "not found" });
    log("-> 404");
  } catch (err) {
    process.stderr.write(
      `spec-server: handler threw ${(err && err.stack) || err}\n`,
    );
    if (!res.headersSent) {
      sendJson(res, 500, { error: "internal" });
    }
  }
});

server.listen(PORT, BIND, () => {
  process.stdout.write(
    `[spec-server] listening on ${BIND}:${PORT} (display=${DISPLAY})\n`,
  );
  process.stdout.write(
    `[spec-server] player bindings file: ${PLAYER_BINDINGS_PATH}\n`,
  );
});

for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => {
    server.close(() => process.exit(0));
  });
}
