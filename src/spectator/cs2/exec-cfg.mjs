import { writeFileSync, renameSync } from "node:fs";
import process from "node:process";

import { EXEC_CFG_KEY } from "../constants.mjs";
import { EXEC_CFG_PATH } from "../env.mjs";
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

// For a cmd that must never be typed where the stream can see it: no console
// fallback, and `deliver` runs only once the cfg holds the cmd, inside the chain
// so no other input lands in the middle of it.
export async function execCfgUntyped(cmd, deliver) {
  return serialized(async () => {
    if (!writeExecCfg(cmd)) {
      return "unwritable";
    }
    return (await deliver()) ? "sent" : "unreachable";
  });
}

// Via sendKey so the flush key gets the same focus recovery as every other
// input path — a raw xdotool key silently no-ops when focus has drifted.
export function execCfgFromBind() {
  return sendKey(EXEC_CFG_KEY);
}

// For where the BACKSPACE bind can't fire (the main menu and its Disconnected
// dialog).
export function execCfgFromConsole() {
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
