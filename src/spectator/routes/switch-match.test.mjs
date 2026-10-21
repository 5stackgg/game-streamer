// node --test src/spectator/routes/switch-match.test.mjs
import { before, beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import process from "node:process";

import { applyGsiUpdate } from "../state/gsi.mjs";

const root = mkdtempSync(join(tmpdir(), "switch-match-"));
const cfgDir = join(root, "cfg");
const execCfg = join(cfgDir, "5stack_exec.cfg");
const execCfgTmp = `${execCfg}.tmp`;
const keystrokes = join(root, "keystrokes");
let switchMatchHandler;
let directorState;

// xdotool finds cs2 already focused and records every key and typed line, each with
// what the exec cfg held at that moment. The pivot flow is a no-op.
before(async () => {
  const bin = join(root, "bin");
  mkdirSync(bin);
  mkdirSync(cfgDir);
  mkdirSync(join(root, "src", "flows"), { recursive: true });
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
  writeFileSync(join(root, "src", "flows", "switch-match.sh"), "exit 0\n");
  Object.assign(process.env, {
    LOG_DIR: root,
    CS2_CFG_DIR: cfgDir,
    SRC_DIR: join(root, "src"),
    PATH: `${bin}:${process.env.PATH}`,
  });
  ({ switchMatchHandler } = await import("./switch-match.mjs"));
  ({ directorState } = await import("../director/index.mjs"));
});

beforeEach(() => {
  rmSync(keystrokes, { force: true });
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

async function switchMatch(target) {
  const res = {
    writeHead(status) { this.status = status; },
    end(body) { this.body = JSON.parse(body); },
  };
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
