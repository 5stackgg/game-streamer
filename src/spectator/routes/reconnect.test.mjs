// node --test src/spectator/routes/reconnect.test.mjs
import { before, beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import process from "node:process";

import { applyGsiUpdate, gsiState } from "../state/gsi.mjs";

const root = mkdtempSync(join(tmpdir(), "reconnect-"));
const cfgDir = join(root, "cfg");
const execCfg = join(cfgDir, "5stack_exec.cfg");
const keystrokes = join(root, "keystrokes");
let reconnectHandler;
let execCfgCommand;
let execCfgViaConsole;

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
  Object.assign(process.env, {
    LOG_DIR: root,
    CS2_CFG_DIR: cfgDir,
    PATH: `${bin}:${process.env.PATH}`,
  });
  ({ reconnectHandler } = await import("./reconnect.mjs"));
  ({ execCfgCommand, execCfgViaConsole } = await import("../cs2/exec-cfg.mjs"));
});

beforeEach(() => {
  rmSync(keystrokes, { force: true });
  writeFileSync(execCfg, "");
});

function inGame() {
  applyGsiUpdate({ map: { name: "de_mirage", phase: "live" } });
}

function onMenu() {
  applyGsiUpdate({ player: { activity: "menu" } });
}

async function reconnect(target) {
  for (const key of ["PLAYCAST_URL", "CONNECT_TV_ADDR", "CONNECT_TV_PASSWORD", "CONNECT_ADDR", "CONNECT_PASSWORD"]) {
    delete process.env[key];
  }
  Object.assign(process.env, target);
  const res = {
    writeHead(status) { this.status = status; },
    end(body) { this.body = JSON.parse(body); },
  };
  await reconnectHandler(null, res);
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

test("on the menu the console gets only the disconnect and the exec, never the address or password", async () => {
  onMenu();
  const res = await reconnect({ CONNECT_ADDR: "10.0.0.5:27015", CONNECT_PASSWORD: "hunter2" });
  assert.equal(res.status, 200);
  assert.deepEqual(typed(), ["disconnect", "exec 5stack_exec"]);
  assert.deepEqual(ran(), ["disconnect", 'password "hunter2"', "connect 10.0.0.5:27015"]);
});

test("in a game the connect runs through the BACKSPACE bind and the console never opens", async () => {
  inGame();
  const res = await reconnect({ CONNECT_TV_ADDR: "10.0.0.6:27020", CONNECT_TV_PASSWORD: "tvpass" });
  assert.equal(res.status, 200);
  assert.deepEqual(typed(), []);
  assert.deepEqual(ran(), ['password "tvpass"', "connect 10.0.0.6:27020"]);
});

test("a playcast reconnect in a game stays off the console too", async () => {
  inGame();
  const res = await reconnect({ PLAYCAST_URL: "https://tv.example/match-1" });
  assert.equal(res.status, 200);
  assert.deepEqual(typed(), []);
  assert.deepEqual(ran(), ['playcast "https://tv.example/match-1"']);
});

test("a map name from GSI that has gone quiet is not taken as being in a game", async () => {
  inGame();
  gsiState.lastReceivedMs -= 60_000;
  const res = await reconnect({ CONNECT_ADDR: "10.0.0.5:27015", CONNECT_PASSWORD: "hunter2" });
  assert.equal(res.status, 200);
  assert.deepEqual(typed(), ["disconnect", "exec 5stack_exec"]);
  assert.deepEqual(ran(), ["disconnect", 'password "hunter2"', "connect 10.0.0.5:27015"]);
});

test("a target that would break out of the cfg is refused before anything reaches cs2", async () => {
  onMenu();
  for (const target of [
    { CONNECT_ADDR: "10.0.0.5:27015", CONNECT_PASSWORD: 'a"; quit; "' },
    { CONNECT_ADDR: "10.0.0.5:27015; quit", CONNECT_PASSWORD: "" },
    { PLAYCAST_URL: "https://tv.example/x\nquit" },
  ]) {
    const res = await reconnect(target);
    assert.equal(res.status, 400, JSON.stringify(target));
  }
  assert.deepEqual(inputs(), []);
  assert.equal(readFileSync(execCfg, "utf8"), "");
});

test("an exec-cfg command sent alongside waits until the console exec has read the cfg", async () => {
  await Promise.all([
    execCfgViaConsole('password "hunter2"; connect 10.0.0.5:27015'),
    execCfgCommand("+showscores"),
  ]);
  assert.deepEqual(ran(), ['password "hunter2"', "connect 10.0.0.5:27015", "+showscores"]);
});
