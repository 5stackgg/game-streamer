// node --test src/spectator/routes/switch-match.test.mjs
import { after, before, beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import process from "node:process";
import { Readable } from "node:stream";
import { setTimeout as sleep } from "node:timers/promises";

import { applyGsiUpdate } from "../state/gsi.mjs";

const root = mkdtempSync(join(tmpdir(), "switch-match-"));
const cfgDir = join(root, "cfg");
const execCfg = join(cfgDir, "5stack_exec.cfg");
const execCfgTmp = `${execCfg}.tmp`;
const keystrokes = join(root, "keystrokes");
const seeded = join(root, "seeded");
const flows = join(root, "flows");
const apiCalls = [];
let switchMatchHandler;
let directorState;
let gsiHandler;
let reconnectHandler;
let cameraWhepHandler;
let resetSidesState;

// xdotool finds cs2 already focused and records every key and typed line, each with
// what the exec cfg held at that moment. The pivot flow is a no-op, the HUD seed
// records which match it was asked for, and the api answers every call. The pod
// booted streaming match-a.
before(async () => {
  const bin = join(root, "bin");
  mkdirSync(bin);
  mkdirSync(cfgDir);
  mkdirSync(join(root, "src", "flows"), { recursive: true });
  mkdirSync(join(root, "src", "lib"), { recursive: true });
  writeFileSync(
    join(bin, "xdotool"),
    `#!/bin/sh
log() { printf '%s\\t%s\\n' "$1" "$(tr '\\n' '|' <"${execCfg}")" >>"${keystrokes}"; }
case "$1" in
  search|getwindowfocus) echo 0x1 ;;
  key) log "key $3" ;;
  type) log "type $4" ;;
esac
`,
  );
  chmodSync(join(bin, "xdotool"), 0o755);
  writeFileSync(join(root, "src", "flows", "switch-match.sh"), `printf '%s\\n' "\${STREAM_ID:-<unset>}" >>"${flows}"\n`);
  writeFileSync(
    join(root, "src", "lib", "hud-manager.sh"),
    `seed_hud_db() { printf '%s\\n' "$1" >>"${seeded}"; }\n`,
  );
  globalThis.fetch = async (url, init) => {
    apiCalls.push({ url: String(url), headers: init?.headers ?? {} });
    return new Response("answer-sdp", { status: 200 });
  };
  Object.assign(process.env, {
    LOG_DIR: root,
    CS2_CFG_DIR: cfgDir,
    SRC_DIR: join(root, "src"),
    PATH: `${bin}:${process.env.PATH}`,
    AUTODIRECTOR: "0",
    STATUS_API_BASE: "http://api.test",
    MATCH_ID: "match-a",
    MATCH_PASSWORD: "match-a-password",
    CONNECT_TV_ADDR: "10.0.0.5:27020",
    CONNECT_TV_PASSWORD: "match-a-tv",
  });
  ({ switchMatchHandler } = await import("./switch-match.mjs"));
  ({ directorState } = await import("../director/index.mjs"));
  ({ gsiHandler } = await import("./gsi.mjs"));
  ({ reconnectHandler } = await import("./reconnect.mjs"));
  ({ cameraWhepHandler } = await import("./camera.mjs"));
  ({ resetSidesState } = await import("../reporters/sides.mjs"));
  const { playingState } = await import("../reporters/demo-playing.mjs");
  playingState.reported = true;
});

after(() => {
  rmSync(root, { recursive: true, force: true });
});

beforeEach(() => {
  resetSidesState();
  rmSync(keystrokes, { force: true });
  rmSync(seeded, { force: true });
  rmSync(flows, { force: true });
  apiCalls.length = 0;
  rmSync(execCfgTmp, { recursive: true, force: true });
  writeFileSync(execCfg, "");
  directorState.bootstrapped = true;
});

function inGame() {
  applyGsiUpdate({ map: { name: "de_mirage", phase: "live" } });
}

function onMenu() {
  applyGsiUpdate({ player: { activity: "menu" } });
}

function response() {
  return {
    writeHead(status, headers) { this.status = status; this.type = headers["Content-Type"]; },
    end(body) { this.body = this.type === "application/json" ? JSON.parse(body) : String(body); },
  };
}

async function switchMatch(target) {
  const res = response();
  await switchMatchHandler(null, res, {
    matchId: "match-b",
    oldMatchId: "match-a",
    matchPassword: "match-b-password",
    mode: "live",
    ...target,
  });
  return res;
}

function inputs() {
  if (!existsSync(keystrokes)) {
    return [];
  }
  return readFileSync(keystrokes, "utf8").split("\n").filter(Boolean).map((line) => {
    const [input, cfg] = line.split("\t");
    return { input, cfg: cfg.split("|").filter(Boolean) };
  });
}

// What shows on the stream: every line typed into the console.
function typed() {
  return inputs().filter(({ input }) => input.startsWith("type ")).map(({ input }) => input.slice(5));
}

// What cs2 runs: a typed line on Return (`exec 5stack_exec` runs the cfg as it is at
// that moment), and the cfg on BACKSPACE.
function ran() {
  const commands = [];
  let line = null;
  for (const { input, cfg } of inputs()) {
    if (input.startsWith("type ")) {
      line = input.slice(5);
    } else if (input === "key Return") {
      commands.push(...(line === "exec 5stack_exec" ? cfg : [line]));
      line = null;
    } else if (input === "key BackSpace") {
      commands.push(...cfg);
    }
  }
  return commands;
}

const CONNECT = { connect: { addr: "10.0.0.7:27015", password: "hunter2" } };

test("in a game the switch runs through the BACKSPACE bind and the console never opens", async () => {
  inGame();
  const res = await switchMatch(CONNECT);
  assert.equal(res.status, 200);
  assert.deepEqual(typed(), []);
  assert.deepEqual(ran(), ['password "hunter2"', "connect 10.0.0.7:27015"]);
});

test("a playcast switch in a game stays off the console too", async () => {
  inGame();
  const res = await switchMatch({ mode: "tv", playcastUrl: "https://tv.example/match-b" });
  assert.equal(res.status, 200);
  assert.deepEqual(typed(), []);
  assert.deepEqual(ran(), ['playcast "https://tv.example/match-b"']);
});

test("on the menu the console gets only the disconnect and the exec, never the address or password", async () => {
  onMenu();
  const res = await switchMatch(CONNECT);
  assert.equal(res.status, 200);
  assert.deepEqual(typed(), ["disconnect", "exec 5stack_exec"]);
  assert.deepEqual(ran(), ["disconnect", 'password "hunter2"', "connect 10.0.0.7:27015"]);
});

// The cfg write goes through a .tmp file, so a directory in its place fails it even
// for root.
for (const [where, enter] of [["in a game", inGame], ["on the menu", onMenu]]) {
  test(`a cfg that can't be written ${where} answers 503 with nothing sent to cs2 and the pod left on its match`, async () => {
    mkdirSync(execCfgTmp);
    enter();
    const res = await switchMatch(CONNECT);
    assert.deepEqual(inputs(), []);
    assert.equal(res.status, 503);
    assert.deepEqual(res.body, { error: "exec cfg could not be written" });
    assert.equal(directorState.bootstrapped, true);
  });
}

const STEAM_ID = "76561198000000001";

function gsi(body) {
  gsiHandler(null, response(), body);
}

async function reconnect() {
  const res = response();
  await reconnectHandler(null, res);
  return res;
}

async function whep(steamId) {
  const req = Object.assign(Readable.from([Buffer.from("offer-sdp")]), { url: `/camera/${steamId}/whep` });
  const res = response();
  await cameraWhepHandler(req, res);
  return res;
}

async function lines(path, count) {
  for (let i = 0; i < 100 && (!existsSync(path) || readFileSync(path, "utf8").split("\n").filter(Boolean).length < count); i++) {
    await sleep(50);
  }
  await sleep(100);
  return existsSync(path) ? readFileSync(path, "utf8").split("\n").filter(Boolean) : [];
}

const seededMatches = () => lines(seeded, 1);

test("a map change after a switch reseeds the HUD with the match the pod switched to", async () => {
  gsi({ map: { name: "de_mirage", phase: "live" } });
  assert.equal((await switchMatch(CONNECT)).status, 200);
  rmSync(seeded, { force: true });
  gsi({ map: { name: "de_inferno", phase: "live" } });
  assert.deepEqual(await seededMatches(), ["match-b"]);
});

for (const [kind, target, dialed] of [
  ["server", CONNECT, ['password "hunter2"', "connect 10.0.0.7:27015"]],
  ["playcast", { mode: "tv", playcastUrl: "https://tv.example/match-b" }, ['playcast "https://tv.example/match-b"']],
]) {
  test(`a reconnect after a switch to a ${kind} dials the match the pod switched to`, async () => {
    inGame();
    assert.equal((await switchMatch(target)).status, 200);
    rmSync(keystrokes, { force: true });
    const res = await reconnect();
    assert.equal(res.status, 200);
    assert.deepEqual(ran(), dialed);
  });
}

test("the camera proxy signs in as the match the pod switched to", async () => {
  inGame();
  assert.equal((await switchMatch(CONNECT)).status, 200);
  applyGsiUpdate({ map: { name: "de_mirage", phase: "live" }, player: { steamid: STEAM_ID } });
  const res = await whep(STEAM_ID);
  assert.equal(res.status, 200);
  assert.deepEqual(apiCalls.map(({ url, headers }) => [url, headers["x-origin-auth"]]), [
    [`http://api.test/matches/camera/broadcast/match-b/${STEAM_ID}/whep`, "match-b:match-b-password"],
  ]);
});

test("a switch the api names no old match for reports the match the pod switched to last", async () => {
  inGame();
  assert.equal((await switchMatch(CONNECT)).status, 200);
  const res = await switchMatch({ ...CONNECT, matchId: "match-c", oldMatchId: undefined });
  assert.equal(res.status, 200);
  assert.equal(res.body.oldMatchId, "match-b");
});

test("a switch that answers 503 leaves reconnects on the match the pod was already on", async () => {
  inGame();
  assert.equal((await switchMatch(CONNECT)).status, 200);
  mkdirSync(execCfgTmp);
  const failed = await switchMatch({ matchId: "match-c", connect: { addr: "10.0.0.8:27015", password: "other" } });
  assert.equal(failed.status, 503);
  rmSync(execCfgTmp, { recursive: true, force: true });
  rmSync(keystrokes, { force: true });
  assert.equal((await reconnect()).status, 200);
  assert.deepEqual(ran(), ['password "hunter2"', "connect 10.0.0.7:27015"]);
});

test("every switch hands the flow the stream the pod booted on, which the capture keeps publishing", async () => {
  inGame();
  assert.equal((await switchMatch(CONNECT)).status, 200);
  assert.equal((await switchMatch({ ...CONNECT, matchId: "match-c", oldMatchId: "match-b" })).status, 200);
  assert.equal((await switchMatch({ ...CONNECT, matchId: "match-d", oldMatchId: undefined })).status, 200);
  assert.deepEqual(await lines(flows, 3), ["match-a", "match-a", "match-a"]);
});

function freezetime(ctName, tName) {
  const map = { name: "de_mirage", phase: "live", team_ct: { name: ctName }, team_t: { name: tName } };
  gsi({ map, round: { phase: "live" } });
  gsi({ map, round: { phase: "freezetime" } });
}

const sideSwaps = () => apiCalls.filter(({ url }) => url.endsWith("/reverse-side")).length;

test("a switch to a match on the same map takes its sides as they start, and still follows its halftime", async () => {
  freezetime("Team A1", "Team A2");
  assert.equal((await switchMatch(CONNECT)).status, 200);
  freezetime("Team B1", "Team B2");
  assert.equal(sideSwaps(), 0);
  freezetime("Team B2", "Team B1");
  assert.equal(sideSwaps(), 1);
});

// cs2 can post a GSI update or two from the match it is leaving after the switch
// was sent.
test("a late freezetime from the match the pod left doesn't flip the new match's sides", async () => {
  freezetime("Team A1", "Team A2");
  assert.equal((await switchMatch(CONNECT)).status, 200);
  freezetime("Team A1", "Team A2");
  freezetime("Team B1", "Team B2");
  assert.equal(sideSwaps(), 0);
  freezetime("Team B2", "Team B1");
  assert.equal(sideSwaps(), 1);
});

test("a switch queued behind another picks the console or the bind from where the client is once its turn comes", async () => {
  onMenu();
  const first = switchMatch(CONNECT);
  await sleep(300);
  inGame();
  const second = switchMatch({ matchId: "match-c", connect: { addr: "10.0.0.8:27015", password: "other" } });
  await sleep(100);
  onMenu();
  assert.equal((await first).status, 200);
  assert.equal((await second).status, 200);
  assert.deepEqual(typed(), ["disconnect", "exec 5stack_exec", "disconnect", "exec 5stack_exec"]);
  assert.deepEqual(ran().slice(-2), ['password "other"', "connect 10.0.0.8:27015"]);
});

const OTHER = { connect: { addr: "10.0.0.8:27015", password: "other" } };

test("a reconnect queued behind a switch dials the match the switch moved to", async () => {
  inGame();
  assert.equal((await switchMatch({ ...OTHER, matchId: "match-c" })).status, 200);
  onMenu();
  const switched = switchMatch(CONNECT);
  await sleep(200);
  const reconnected = reconnect();
  assert.equal((await switched).status, 200);
  assert.equal((await reconnected).status, 200);
  assert.deepEqual(ran().slice(-2), ['password "hunter2"', "connect 10.0.0.7:27015"]);
});

test("a switch queued behind another, with no old match named, reports the one the first moved to", async () => {
  inGame();
  assert.equal((await switchMatch({ ...OTHER, matchId: "match-c" })).status, 200);
  onMenu();
  const first = switchMatch(CONNECT);
  await sleep(200);
  const second = switchMatch({ ...OTHER, matchId: "match-d", oldMatchId: undefined });
  assert.equal((await first).status, 200);
  assert.equal((await second).body.oldMatchId, "match-b");
});
