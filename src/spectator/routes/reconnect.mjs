import process from "node:process";

import { execCfgCommand, execCfgViaConsole } from "../cs2/exec-cfg.mjs";
import { sendConsoleCommand } from "../cs2/input.mjs";
import { findCs2Window } from "../cs2/window.mjs";
import { gsiState } from "../state/gsi.mjs";
import { sendJson } from "../util/http.mjs";

const NON_BLANK = /\S/;
function isNonBlankString(v) {
  return typeof v === "string" && NON_BLANK.test(v);
}

const UNSAFE_CFG_CHARS = /[";\r\n]/;
function hasUnsafeCfgChars(v) {
  return typeof v === "string" && UNSAFE_CFG_CHARS.test(v);
}

// GSI heartbeats every second, so a map name older than this is a client that
// left the game without saying so.
const GSI_IN_GAME_MAX_AGE_MS = 5_000;

function inGame() {
  return gsiState.mapName !== null && Date.now() - gsiState.lastReceivedMs < GSI_IN_GAME_MAX_AGE_MS;
}

// Binds don't fire on the main menu or behind its Disconnected dialog, so from
// there the console is the only way in. A disconnect run in the same batch as the
// connect drops cs2 to the menu before the connect runs, hence the gap.
async function reconnectFromMenu(followUp) {
  if (!(await sendConsoleCommand("disconnect"))) {
    return false;
  }
  await new Promise((r) => setTimeout(r, 1000));
  return execCfgViaConsole(followUp);
}

function resolveTarget() {
  if (isNonBlankString(process.env.PLAYCAST_URL)) {
    return { kind: "playcast", url: process.env.PLAYCAST_URL };
  }
  if (isNonBlankString(process.env.CONNECT_TV_ADDR)) {
    return {
      kind: "connect",
      addr: process.env.CONNECT_TV_ADDR,
      password: process.env.CONNECT_TV_PASSWORD ?? "",
    };
  }
  if (isNonBlankString(process.env.CONNECT_ADDR)) {
    return {
      kind: "connect",
      addr: process.env.CONNECT_ADDR,
      password: process.env.CONNECT_PASSWORD ?? "",
    };
  }
  return null;
}

export async function reconnectHandler(_req, res) {
  if ((await findCs2Window()) === null) {
    sendJson(res, 503, { error: "cs2 not running" });
    return;
  }

  const target = resolveTarget();
  if (!target) {
    sendJson(res, 409, {
      error:
        "no connect target on this pod — PLAYCAST_URL / CONNECT_TV_ADDR / CONNECT_ADDR all unset",
    });
    return;
  }

  let followUp;
  if (target.kind === "playcast") {
    if (hasUnsafeCfgChars(target.url)) {
      sendJson(res, 400, { error: "playcast url contains unsafe characters" });
      return;
    }
    followUp = `playcast "${target.url}"`;
  } else {
    if (hasUnsafeCfgChars(target.addr) || hasUnsafeCfgChars(target.password)) {
      sendJson(res, 400, { error: "connect target contains unsafe characters" });
      return;
    }
    followUp = `password "${target.password}"; connect ${target.addr}`;
  }

  // In a game `connect`/`playcast` leave the current one themselves.
  const viaBind = inGame();
  const ok = viaBind ? await execCfgCommand(followUp) : await reconnectFromMenu(followUp);
  if (!ok) {
    sendJson(res, 503, { error: "cs2 console unreachable" });
    return;
  }

  process.stderr.write(
    `[spec-server] reconnect (${target.kind} via ${viaBind ? "bind" : "console"}) -> ${target.addr ?? target.url}\n`,
  );
  sendJson(res, 200, { ok: true, kind: target.kind });
}
