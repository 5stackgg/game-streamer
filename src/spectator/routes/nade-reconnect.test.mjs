// node --test src/spectator/routes/nade-reconnect.test.mjs
import { after, before, beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import process from "node:process";
import { Readable } from "node:stream";

import { applyGsiUpdate, gsiState } from "../state/gsi.mjs";

const root = mkdtempSync(join(tmpdir(), "nade-reconnect-"));
const cfgDir = join(root, "cfg");
const execCfg = join(cfgDir, "5stack_exec.cfg");
const execCfgTmp = `${execCfg}.tmp`;
const keystrokes = join(root, "keystrokes");
let dispatch;

// xdotool finds cs2 already focused and records every key and typed line, each with
// what the exec cfg held at that moment.
before(async () => {
  const bin = join(root, "bin");
  mkdirSync(bin);
  mkdirSync(cfgDir);
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
  delete process.env.SPEC_SERVER_TOKEN;
  Object.assign(process.env, {
    LOG_DIR: root,
    CS2_CFG_DIR: cfgDir,
    PATH: `${bin}:${process.env.PATH}`,
  });
  ({ dispatch } = await import("./index.mjs"));
});

after(() => {
  rmSync(root, { recursive: true, force: true });
});

beforeEach(() => {
  rmSync(keystrokes, { force: true });
  rmSync(execCfgTmp, { recursive: true, force: true });
  writeFileSync(execCfg, "");
});

function inGame() {
  applyGsiUpdate({ map: { name: "de_mirage", phase: "live" }, player: { activity: "playing" } });
}

function onMenu() {
  applyGsiUpdate({ player: { activity: "menu" } });
}

async function reconnect(body) {
  const req = Object.assign(Readable.from([Buffer.from(JSON.stringify(body))]), {
    method: "POST",
    url: "/nade/reconnect",
    headers: {},
    socket: { remoteAddress: "127.0.0.1" },
  });
  const res = {
    headersSent: false,
    writeHead(status) { this.status = status; this.headersSent = true; },
    end(body) { this.body = JSON.parse(body); },
  };
  await dispatch(req, res);
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

const TARGET = { addr: "127.0.0.1:27015", password: "hunter2" };

test("a client on the main menu reconnects through the console, which never shows the password", async () => {
  onMenu();
  const res = await reconnect(TARGET);
  assert.equal(res.status, 200);
  assert.deepEqual(typed(), ["disconnect", "exec 5stack_exec"]);
  assert.deepEqual(ran(), ["disconnect", 'password "hunter2"', "connect 127.0.0.1:27015"]);
});

test("a client whose GSI went quiet when the server dropped it takes the console path too", async () => {
  inGame();
  gsiState.lastReceivedMs -= 60_000;
  const res = await reconnect(TARGET);
  assert.equal(res.status, 200);
  assert.deepEqual(typed(), ["disconnect", "exec 5stack_exec"]);
  assert.deepEqual(ran(), ["disconnect", 'password "hunter2"', "connect 127.0.0.1:27015"]);
});

test("a client in a game reconnects through the BACKSPACE bind and the console never opens", async () => {
  inGame();
  const res = await reconnect(TARGET);
  assert.equal(res.status, 200);
  assert.deepEqual(typed(), []);
  assert.deepEqual(ran(), ['password "hunter2"', "connect 127.0.0.1:27015"]);
});

test("a server without a password reconnects with an empty one", async () => {
  inGame();
  const res = await reconnect({ addr: "127.0.0.1:27015", password: "" });
  assert.equal(res.status, 200);
  assert.deepEqual(ran(), ['password ""', "connect 127.0.0.1:27015"]);
});

test("a target that is missing or would break out of the cfg is refused before anything reaches cs2", async () => {
  onMenu();
  for (const body of [
    {},
    { addr: " ", password: "hunter2" },
    { addr: "127.0.0.1:27015" },
    { addr: "127.0.0.1:27015", password: 'a"; quit; "' },
    { addr: "127.0.0.1:27015; quit", password: "" },
    { addr: "127.0.0.1:27015", password: "a\nquit" },
  ]) {
    const res = await reconnect(body);
    assert.equal(res.status, 400, JSON.stringify(body));
  }
  assert.deepEqual(inputs(), []);
  assert.equal(readFileSync(execCfg, "utf8"), "");
});

// The cfg write goes through a .tmp file, so a directory in its place fails it even
// for root.
for (const [where, enter] of [["in a game", inGame], ["on the menu", onMenu]]) {
  test(`a cfg that can't be written ${where} answers 503 with nothing sent to cs2`, async () => {
    mkdirSync(execCfgTmp);
    enter();
    const res = await reconnect(TARGET);
    assert.deepEqual(inputs(), []);
    assert.equal(res.status, 503);
    assert.deepEqual(res.body, { error: "exec cfg could not be written" });
  });
}
