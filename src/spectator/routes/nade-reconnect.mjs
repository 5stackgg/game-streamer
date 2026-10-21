import process from "node:process";

import { execCfgConnect } from "../cs2/exec-cfg.mjs";
import { findCs2Window } from "../cs2/window.mjs";
import { sendJson } from "../util/http.mjs";

const NON_BLANK = /\S/;
function isNonBlankString(v) {
  return typeof v === "string" && NON_BLANK.test(v);
}

const UNSAFE_CFG_CHARS = /[";\r\n]/;
function hasUnsafeCfgChars(v) {
  return typeof v === "string" && UNSAFE_CFG_CHARS.test(v);
}

// run-nades.sh picks which practice server the pod plays on, so the caller
// names it rather than this reading the env the way /spec/reconnect does.
export async function nadeReconnectHandler(_req, res, body) {
  const { addr, password } = body;
  if (!isNonBlankString(addr) || typeof password !== "string") {
    sendJson(res, 400, { error: "addr and password required" });
    return;
  }
  if (hasUnsafeCfgChars(addr) || hasUnsafeCfgChars(password)) {
    sendJson(res, 400, { error: "connect target contains unsafe characters" });
    return;
  }

  if ((await findCs2Window()) === null) {
    sendJson(res, 503, { error: "cs2 not running" });
    return;
  }

  const { sent, via } = await execCfgConnect(`password "${password}"; connect ${addr}`);
  if (sent === "unwritable") {
    sendJson(res, 503, { error: "exec cfg could not be written" });
    return;
  }
  if (sent === "unreachable") {
    sendJson(res, 503, { error: "cs2 console unreachable" });
    return;
  }

  process.stderr.write(`[spec-server] nade reconnect (via ${via}) -> ${addr}\n`);
  sendJson(res, 200, { ok: true });
}
