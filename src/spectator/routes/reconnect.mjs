import process from "node:process";

import { execCfgConnect } from "../cs2/exec-cfg.mjs";
import { findCs2Window } from "../cs2/window.mjs";
import { podTarget } from "../state/pod-target.mjs";
import { sendJson } from "../util/http.mjs";

const UNSAFE_CFG_CHARS = /[";\r\n]/;
function hasUnsafeCfgChars(v) {
  return typeof v === "string" && UNSAFE_CFG_CHARS.test(v);
}

function refusal(target) {
  if (!target) {
    return {
      status: 409,
      error:
        "no connect target on this pod — PLAYCAST_URL / CONNECT_TV_ADDR / CONNECT_ADDR all unset",
    };
  }
  if (target.kind === "playcast") {
    if (hasUnsafeCfgChars(target.url)) {
      return { status: 400, error: "playcast url contains unsafe characters" };
    }
    return null;
  }
  if (hasUnsafeCfgChars(target.addr) || hasUnsafeCfgChars(target.password)) {
    return { status: 400, error: "connect target contains unsafe characters" };
  }
  return null;
}

function connectCommand(target) {
  if (target.kind === "playcast") {
    return `playcast "${target.url}"`;
  }
  return `password "${target.password}"; connect ${target.addr}`;
}

export async function reconnectHandler(_req, res) {
  if ((await findCs2Window()) === null) {
    sendJson(res, 503, { error: "cs2 not running" });
    return;
  }

  // Read in the queue: a switch ahead of this one moves the pod's target.
  let target = null;
  let refused = null;
  const { sent, via } = await execCfgConnect(() => {
    target = podTarget().connect;
    refused = refusal(target);
    return refused ? null : connectCommand(target);
  });
  if (refused) {
    sendJson(res, refused.status, { error: refused.error });
    return;
  }
  if (sent === "unwritable") {
    sendJson(res, 503, { error: "exec cfg could not be written" });
    return;
  }
  if (sent === "unreachable") {
    sendJson(res, 503, { error: "cs2 console unreachable" });
    return;
  }

  process.stderr.write(
    `[spec-server] reconnect (${target.kind} via ${via}) -> ${target.addr ?? target.url}\n`,
  );
  sendJson(res, 200, { ok: true, kind: target.kind });
}
