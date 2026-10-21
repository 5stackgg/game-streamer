import process from "node:process";

import { execCfgConnect } from "../cs2/exec-cfg.mjs";
import { findCs2Window } from "../cs2/window.mjs";
import { podTarget } from "../state/pod-target.mjs";
import { sendJson } from "../util/http.mjs";

const UNSAFE_CFG_CHARS = /[";\r\n]/;
function hasUnsafeCfgChars(v) {
  return typeof v === "string" && UNSAFE_CFG_CHARS.test(v);
}

export async function reconnectHandler(_req, res) {
  if ((await findCs2Window()) === null) {
    sendJson(res, 503, { error: "cs2 not running" });
    return;
  }

  const target = podTarget().connect;
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

  const { sent, via } = await execCfgConnect(followUp);
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
