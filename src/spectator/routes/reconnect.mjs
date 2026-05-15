import process from "node:process";

import { execCfgCommand } from "../cs2/exec-cfg.mjs";
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

  let script;
  if (target.kind === "playcast") {
    if (hasUnsafeCfgChars(target.url)) {
      sendJson(res, 400, { error: "playcast url contains unsafe characters" });
      return;
    }
    script = `disconnect; playcast "${target.url}"`;
  } else {
    if (hasUnsafeCfgChars(target.addr) || hasUnsafeCfgChars(target.password)) {
      sendJson(res, 400, { error: "connect target contains unsafe characters" });
      return;
    }
    script = `disconnect; password "${target.password}"; connect ${target.addr}`;
  }

  const ok = await execCfgCommand(script);
  if (!ok) {
    sendJson(res, 503, { error: "cs2 console unreachable" });
    return;
  }

  process.stderr.write(
    `[spec-server] reconnect (${target.kind}) -> ${target.addr ?? target.url}\n`,
  );
  sendJson(res, 200, { ok: true, kind: target.kind });
}
