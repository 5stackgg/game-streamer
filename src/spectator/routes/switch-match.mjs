// Hot-swap the running pod onto a different match. Saves the boot
// time of tearing down + bringing up a fresh game-streamer pod
// (steam + cs2 launch = ~60-180s) — instead we instruct cs2 to
// `disconnect; connect <new>` and pivot the capture / HUD / status
// reporter to the new match id.
//
// Body shape (POSTed by api/GameStreamerService.switchLive):
//   {
//     matchId:        string            // new match id (target)
//     oldMatchId:     string            // previous match id (for stop_capture)
//     matchPassword:  string            // raw match password (status reporter auth)
//     mode:           "live" | "tv"
//     connect: {                        // EITHER...
//       addr:     "host:port"
//       password: string
//     }
//     playcastUrl?:   string            // ...OR for tv+playcast
//   }
//
// Non-blocking — cs2's disconnect/connect happens synchronously here
// (sub-second), and the slower pivots (capture restart, HUD reseed,
// reporter rebind) run in a detached bash flow so the api response
// doesn't sit on them.

import { spawn } from "node:child_process";
import process from "node:process";

import { SRC_DIR } from "../env.mjs";
import { findCs2Window } from "../cs2/window.mjs";
import { execCfgConnect } from "../cs2/exec-cfg.mjs";
import { directorState, stopDirector } from "../director/index.mjs";
import { sendJson } from "../util/http.mjs";

const NON_BLANK = /\S/;

function isNonBlankString(v) {
  return typeof v === "string" && NON_BLANK.test(v);
}

// execCfgCommand splits on `;` and writes quoted args to a cfg file
// cs2 `exec`s — `;`/`"`/newline in interpolated values breaks either
// the split or cs2's quoted-string parser.
const UNSAFE_CFG_CHARS = /[";\r\n]/;
function hasUnsafeCfgChars(v) {
  return typeof v === "string" && UNSAFE_CFG_CHARS.test(v);
}

function validate(body) {
  if (!body || typeof body !== "object") return "body required";
  if (!isNonBlankString(body.matchId)) return "matchId required";
  if (body.mode !== "live" && body.mode !== "tv") return "mode must be live|tv";
  if (!isNonBlankString(body.matchPassword)) return "matchPassword required";
  const hasPlaycast = isNonBlankString(body.playcastUrl);
  const hasConnect =
    body.connect &&
    isNonBlankString(body.connect.addr) &&
    typeof body.connect.password === "string";
  if (!hasPlaycast && !hasConnect) {
    return "connect{addr,password} or playcastUrl required";
  }
  if (hasPlaycast && hasUnsafeCfgChars(body.playcastUrl)) {
    return "playcastUrl contains unsafe characters";
  }
  if (hasConnect) {
    if (hasUnsafeCfgChars(body.connect.addr)) {
      return "connect.addr contains unsafe characters";
    }
    if (hasUnsafeCfgChars(body.connect.password)) {
      return "connect.password contains unsafe characters";
    }
  }
  return null;
}

function consoleScript(body) {
  if (isNonBlankString(body.playcastUrl)) {
    return `playcast "${body.playcastUrl}"`;
  }
  return `password "${body.connect.password}"; connect ${body.connect.addr}`;
}

function spawnSwitchFlow(body, oldMatchId) {
  // SRC_DIR is the in-pod /opt/game-streamer/src mount; flows/ holds
  // the bash entrypoints that already know how to drive cs2-perf,
  // HUD, status-reporter etc. Detached so the curl ACK to api isn't
  // gated on a 5-10s capture restart.
  const env = {
    ...process.env,
    // Anything previously exported on the pod for the OLD match is
    // intentionally clobbered here so the flow inherits a clean
    // target — bash scripts read these without re-validating.
    MATCH_ID: body.matchId,
    MATCH_PASSWORD: body.matchPassword,
    OLD_MATCH_ID: oldMatchId || "",
    MODE: body.mode,
  };

  // The capture restart needs to know how to dial back into the new
  // game server even if the bash flow somehow has to re-launch cs2.
  // For "live" mode we forward CONNECT_ADDR/CONNECT_PASSWORD; for
  // "tv"+playcast we forward PLAYCAST_URL. Unset the alternates to
  // keep run-live.sh's mode-precedence (playcast → tv → live) sane.
  if (isNonBlankString(body.playcastUrl)) {
    env.PLAYCAST_URL = body.playcastUrl;
    env.PLAYCAST_PASSWORD = "";
    delete env.CONNECT_ADDR;
    delete env.CONNECT_PASSWORD;
    delete env.CONNECT_TV_ADDR;
    delete env.CONNECT_TV_PASSWORD;
  } else {
    env.CONNECT_ADDR = body.connect.addr;
    env.CONNECT_PASSWORD = body.connect.password;
    delete env.PLAYCAST_URL;
    delete env.PLAYCAST_PASSWORD;
    delete env.CONNECT_TV_ADDR;
    delete env.CONNECT_TV_PASSWORD;
  }

  const script = `${SRC_DIR}/flows/switch-match.sh`;
  const child = spawn("bash", [script], {
    env,
    stdio: ["ignore", "inherit", "inherit"],
    detached: true,
  });
  // Don't keep the spec-server alive waiting on this — the bash flow
  // owns its own lifetime and writes status via the reporter.
  child.unref();
  return child.pid;
}

export async function switchMatchHandler(_req, res, body) {
  const err = validate(body);
  if (err) {
    sendJson(res, 400, { error: err });
    return;
  }

  if ((await findCs2Window()) === null) {
    sendJson(res, 503, { error: "cs2 not running" });
    return;
  }

  const oldMatchId = isNonBlankString(body.oldMatchId)
    ? body.oldMatchId
    : process.env.MATCH_ID || "";

  const { sent, via } = await execCfgConnect(consoleScript(body));
  if (sent === "unwritable") {
    sendJson(res, 503, { error: "exec cfg could not be written" });
    return;
  }
  if (sent === "unreachable") {
    sendJson(res, 503, { error: "cs2 console unreachable" });
    return;
  }

  stopDirector();
  directorState.bootstrapped = false;

  const pid = spawnSwitchFlow(body, oldMatchId);
  process.stderr.write(
    `[spec-server] switch-match (via ${via}): ${oldMatchId || "<unset>"} -> ${body.matchId} (flow pid=${pid})\n`,
  );

  sendJson(res, 200, {
    ok: true,
    matchId: body.matchId,
    oldMatchId: oldMatchId || null,
    flowPid: pid,
  });
}
