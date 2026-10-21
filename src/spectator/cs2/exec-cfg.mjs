import { writeFileSync, renameSync } from "node:fs";
import process from "node:process";

import { EXEC_CFG_KEY } from "../constants.mjs";
import { EXEC_CFG_PATH } from "../env.mjs";
import { gsiState } from "../state/gsi.mjs";
import { sendConsoleCommand, sendKey } from "./input.mjs";

// Serialized so two in-flight calls can't race the cfg rename
// against BACKSPACE delivery and have cs2 read the wrong contents.
let execCfgChain = Promise.resolve();

async function serialized(fn) {
  const prev = execCfgChain;
  let release;
  execCfgChain = new Promise((r) => { release = r; });
  try {
    await prev.catch(() => undefined);
    return await fn();
  } finally {
    setTimeout(release, 30);
  }
}

export async function execCfgCommand(cmd) {
  return serialized(async () => {
    if (!writeExecCfg(cmd)) {
      return sendConsoleCommand(cmd);
    }
    return execCfgFromBind();
  });
}

// For `connect`/`playcast`, whose address and password must never be typed
// where the stream can see them. In a game either one leaves the current game by
// itself. The path is picked once its turn in the queue comes: a connect queued
// behind another finds the client wherever that one left it.
export async function execCfgConnect(cmd) {
  let via = null;
  const sent = await execCfgUntyped(cmd, () => {
    via = inGame() ? "bind" : "console";
    return via === "bind" ? execCfgFromBind() : disconnectThenExec();
  });
  return { sent, via };
}

// GSI heartbeats every second, so a map name older than this is a client that
// left the game without saying so.
const GSI_IN_GAME_MAX_AGE_MS = 5_000;

function inGame() {
  return (
    gsiState.mapName !== null &&
    gsiState.localActivity !== "menu" &&
    Date.now() - gsiState.lastReceivedMs < GSI_IN_GAME_MAX_AGE_MS
  );
}

// Binds don't fire on the main menu or behind its Disconnected dialog, so from
// there the console is the only way in, and it is on the stream: only the
// disconnect and the exec are typed. A disconnect in the same batch as the
// connect drops cs2 to the menu before the connect runs, hence the gap.
async function disconnectThenExec() {
  if (!(await sendConsoleCommand("disconnect"))) {
    return false;
  }
  await new Promise((r) => setTimeout(r, 1000));
  return execCfgFromConsole();
}

// No console fallback, and `deliver` runs only once the cfg holds the cmd,
// inside the chain so no other input lands in the middle of it.
async function execCfgUntyped(cmd, deliver) {
  return serialized(async () => {
    if (!writeExecCfg(cmd)) {
      return "unwritable";
    }
    return (await deliver()) ? "sent" : "unreachable";
  });
}

// Via sendKey so the flush key gets the same focus recovery as every other
// input path — a raw xdotool key silently no-ops when focus has drifted.
function execCfgFromBind() {
  return sendKey(EXEC_CFG_KEY);
}

// For where the BACKSPACE bind can't fire (the main menu and its Disconnected
// dialog).
function execCfgFromConsole() {
  return sendConsoleCommand("exec 5stack_exec");
}

function writeExecCfg(cmd) {
  if (!EXEC_CFG_PATH) {
    return false;
  }
  // One cmd per line — `;`-joined lines get mis-parsed across cs2 builds.
  const lines = cmd.split(";").map((s) => s.trim()).filter(Boolean);
  const body = lines.join("\n") + "\n";
  try {
    const tmp = `${EXEC_CFG_PATH}.tmp`;
    writeFileSync(tmp, body, "utf8");
    renameSync(tmp, EXEC_CFG_PATH);
    return true;
  } catch (err) {
    process.stderr.write(
      `[spec-server] exec-cfg write failed (${(err && err.message) || err})\n`,
    );
    return false;
  }
}
