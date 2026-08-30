import { gsiState } from "../state/gsi.mjs";
import { armNadeWatch, disarmNadeWatch, nadeWatch, nadeWatchLine } from "../state/nades.mjs";
import { sendJson } from "../util/http.mjs";

function sendLine(res, line) {
  const body = Buffer.from(line);
  res.writeHead(200, {
    "Content-Type": "text/plain",
    "Content-Length": String(body.length),
  });
  res.end(body);
}

// The nade-preview recorder polls this at ~10Hz between triggering a throw and
// stopping the capture, so it's a plain pipe-delimited line like
// /demo/capture-fields rather than JSON:
//   armed|gsi_age_ms|since_arm_ms|thrown|detonated|bloom_ms|active|type|blocks_seen
// gsi_age_ms is -1 before the first GSI event; blocks_seen counts GSI updates
// that carried any grenade at all (0 forever => this client isn't an observer,
// so the caller must fall back to the console-log signal).
export async function nadeWatchStateHandler(_req, res) {
  sendLine(res, nadeWatchLine());
}

// Where THIS client is standing and looking, straight off the GSI `player`
// block — the nade recorder's camera-arrival check:
//   gsi_age_ms|steam_id|team|health|activity|x|y|z|fwd_x|fwd_y|fwd_z
// Empty position/forward fields mean GSI hasn't reported them yet; gsi_age_ms
// is -1 before the first GSI event.
export async function nadeSelfHandler(_req, res) {
  const age = gsiState.lastReceivedMs > 0 ? Date.now() - gsiState.lastReceivedMs : -1;
  const pos = gsiState.localPosition ?? ["", "", ""];
  const fwd = gsiState.localForward ?? ["", "", ""];
  sendLine(res, [
    String(age),
    gsiState.spectatedSteamId ?? "",
    gsiState.localTeam ?? "",
    String(gsiState.localHealth),
    gsiState.localActivity ?? "",
    ...pos.map(String),
    ...fwd.map(String),
  ].join("|"));
}

export async function nadeWatchArmHandler(_req, res, body) {
  if (body?.armed === false) {
    disarmNadeWatch();
    sendJson(res, 200, { ok: true, armed: false });
    return;
  }
  armNadeWatch(typeof body?.type === "string" ? body.type : null);
  sendJson(res, 200, {
    ok: true,
    armed: true,
    type: nadeWatch.wantType,
    blocks_seen: nadeWatch.blocksSeen,
  });
}
