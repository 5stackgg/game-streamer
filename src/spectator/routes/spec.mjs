import {
  KEY_AUTODIRECTOR_OFF,
  KEY_SPEC_JUMP,
  KEY_SPEC_NEXT,
  KEY_SPEC_PREV,
  KEY_XRAY_TOGGLE,
  SLOT_KEYS,
} from "../constants.mjs";
import { existsSync, writeFileSync } from "node:fs";
import path from "node:path";
import { DISPLAY, HUD_HOST, HUD_PORT, LOG_DIR } from "../env.mjs";
import { execCfgCommand } from "../cs2/exec-cfg.mjs";
import { findCs2Window } from "../cs2/window.mjs";
import { sendKey } from "../cs2/input.mjs";
import { loadPlayerBindings } from "../state/bindings.mjs";
import { run } from "../util/run.mjs";
import { sendJson } from "../util/http.mjs";
import { directorState, startDirector, stopDirector } from "../director/index.mjs";
import { gsiState } from "../state/gsi.mjs";

function takeManualControl() {
  directorState.bootstrapped = true;
  if (directorState.enabled) stopDirector();
}

export async function clickHandler(_req, res, body) {
  takeManualControl();
  const key = body.button === "right" ? KEY_SPEC_PREV : KEY_SPEC_NEXT;
  const ok = await sendKey(key);
  sendJson(res, ok ? 200 : 503, ok ? { ok, key } : { error: "cs2 not running" });
}

export async function jumpHandler(_req, res) {
  takeManualControl();
  const ok = await sendKey(KEY_SPEC_JUMP);
  sendJson(res, ok ? 200 : 503, ok ? { ok, key: KEY_SPEC_JUMP } : { error: "cs2 not running" });
}

export async function playerHandler(_req, res, body) {
  const aidInt = Number.parseInt(body.accountid, 10);
  if (!Number.isFinite(aidInt)) {
    sendJson(res, 400, { error: "accountid (int) required" });
    return;
  }
  const key = loadPlayerBindings()[String(aidInt)];
  if (!key) {
    sendJson(res, 404, { error: `no key bound for accountid ${aidInt}` });
    return;
  }
  takeManualControl();
  const ok = await sendKey(key);
  sendJson(res, ok ? 200 : 503, { ok, accountid: aidInt, key });
}

export async function slotHandler(_req, res, body) {
  const slotInt = Number.parseInt(body.slot, 10);
  if (!Number.isFinite(slotInt) || slotInt < 1 || slotInt > 12) {
    sendJson(res, 400, { error: "slot (int 1..12) required" });
    return;
  }
  takeManualControl();
  const key = SLOT_KEYS[slotInt - 1];
  const ok = await sendKey(key);
  sendJson(res, ok ? 200 : 503, ok ? { ok, slot: slotInt, key } : { error: "cs2 not running" });
}

export async function autodirectorHandler(_req, res, body) {
  const enabled = Boolean(body.enabled);
  directorState.bootstrapped = true;
  if (!enabled) {
    stopDirector();
    const ok = await sendKey(KEY_AUTODIRECTOR_OFF);
    sendJson(res, ok ? 200 : 503, ok ? { ok, enabled: false } : { error: "cs2 not running" });
    return;
  }
  if ((await findCs2Window()) === null) {
    sendJson(res, 503, { error: "cs2 not running" });
    return;
  }
  await startDirector();
  sendJson(res, 200, { ok: true, enabled: true });
}

// Path the compositor consumer polls for HUD show/hide (stream.sh seeds it in
// composite mode). Mirror of VKCAP_HUD_CTL / $LOG_DIR/hud-visible.
const HUD_CTL_PATH = path.join(LOG_DIR, "hud-visible");

export async function hudHandler(_req, res, body) {
  const visible = Boolean(body.visible);
  // Composite mode: the HUD is a separate gst compositor input, not part of
  // cs2's frame. Toggle it via the consumer's alpha control file — unmapping
  // the overlay window (the legacy path below) would break the ximagesrc xid
  // grab and freeze the whole composite.
  if (existsSync(HUD_CTL_PATH)) {
    writeFileSync(HUD_CTL_PATH, visible ? "1\n" : "0\n");
    sendJson(res, 200, { ok: true, visible, mode: "composite" });
    return;
  }
  const tree = await run(["xwininfo", "-display", DISPLAY, "-root", "-tree"]);
  let overlayId = null;
  let overlayArea = 0;
  if (tree.code === 0) {
    // Match by size: among jts-hud-manager-class windows the overlay
    // is the only fullscreen-sized one (admin is 1280x720).
    for (const line of tree.stdout.split("\n")) {
      const m = line.match(/^\s*(0x[0-9a-f]+)\s.*?(\d+)x(\d+)\+/);
      if (!m) continue;
      if (!/jts-hud-manager/i.test(line)) continue;
      const w = Number(m[2]), h = Number(m[3]);
      if (w < 1600 || h < 900) continue;
      const area = w * h;
      if (area > overlayArea) { overlayArea = area; overlayId = m[1]; }
    }
  }
  if (!overlayId) {
    sendJson(res, 404, { error: "no hud-manager overlay window" });
    return;
  }
  await run(["xdotool", visible ? "windowmap" : "windowunmap", overlayId]);
  sendJson(res, 200, { ok: true, visible, window: overlayId });
}

// Variant currently shown on the overlay. Seeded from the pod's
// HUD_MODE (the api-resolved default that hud-manager.sh forwards as
// HUD_VARIANT) and updated whenever the operator switches mode below,
// so hudReloadHandler can rebuild the same layout.
let activeHudVariant = process.env.HUD_VARIANT || process.env.HUD_MODE || "horizontal";

async function startDefaultOverlay(variant) {
  const r = await fetch(`http://${HUD_HOST}:${HUD_PORT}/api/overlay/start`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ hudId: "default", variant }),
  });
  if (!r.ok) {
    const text = await r.text().catch(() => "");
    return { ok: false, status: r.status, body: text.slice(0, 200) };
  }
  return { ok: true };
}

// "mode" here maps to a HUD variant — JTs Hud's default bundle
// declares ["default","horizontal","vertical"] in its hud.json and
// switches layout based on the `?variant=` query param (see the admin
// renderer's HudCard.vue buildUrl/launchHud). There's still only one
// HUD id on disk (`default`); horizontal/vertical are not separate
// HUD directories, so this must NOT be sent as `hudId`.
export async function hudModeHandler(_req, res, body) {
  const mode = typeof body.mode === "string" ? body.mode : null;
  const ALLOWED = new Set(["default", "horizontal", "vertical"]);
  if (!mode || !ALLOWED.has(mode)) {
    sendJson(res, 400, { error: "mode must be one of default|horizontal|vertical" });
    return;
  }
  try {
    const r = await startDefaultOverlay(mode);
    if (!r.ok) {
      sendJson(res, 502, { error: "hud-manager rejected overlay/start", status: r.status, body: r.body });
      return;
    }
    activeHudVariant = mode;
    sendJson(res, 200, { ok: true, mode });
  } catch (err) {
    sendJson(res, 502, { error: "hud-manager unreachable", detail: String(err) });
  }
}

// Rebuild the overlay BrowserWindow against the current variant — a
// fresh page load that re-fetches player metadata and images. Lets
// operators push a mid-match image swap to the live HUD without
// flipping layouts (previously the only way to force a reload).
export async function hudReloadHandler(_req, res, _body) {
  try {
    const r = await startDefaultOverlay(activeHudVariant);
    if (!r.ok) {
      sendJson(res, 502, { error: "hud-manager rejected overlay/start", status: r.status, body: r.body });
      return;
    }
    sendJson(res, 200, { ok: true, variant: activeHudVariant });
  } catch (err) {
    sendJson(res, 502, { error: "hud-manager unreachable", detail: String(err) });
  }
}

export async function hudSidesHandler(_req, res, _body) {
  const raw = gsiState.mapName || "";
  const mapName = raw.includes("/") ? raw.substring(raw.lastIndexOf("/") + 1) : raw;
  if (!mapName) {
    sendJson(res, 409, { error: "no current map" });
    return;
  }
  try {
    const r = await fetch(
      `http://${HUD_HOST}:${HUD_PORT}/api/match/current/veto/${encodeURIComponent(mapName)}/reverse-side`,
      { method: "PATCH" },
    );
    if (!r.ok) {
      const text = await r.text().catch(() => "");
      sendJson(res, 502, {
        error: "hud-manager rejected reverse-side",
        status: r.status,
        body: text.slice(0, 200),
      });
      return;
    }
    sendJson(res, 200, { ok: true, mapName });
  } catch (err) {
    sendJson(res, 502, { error: "hud-manager unreachable", detail: String(err) });
  }
}

// X-ray toggle. cs2's built-in `x` keypress cycles spec_show_xray 0↔1
// — caller tracks the intended state locally and we just emit one
// keypress per intent change.
export async function specXrayHandler(_req, res, body) {
  const ok = await sendKey(KEY_XRAY_TOGGLE);
  sendJson(
    res,
    ok ? 200 : 503,
    ok ? { ok, enabled: Boolean(body.enabled) } : { error: "cs2 not running" },
  );
}

// Momentary scoreboard hold: caller fires {show:true} on Tab-down and
// {show:false} on Tab-up. +showscores / -showscores are valid cs2
// console commands; we send them via exec-cfg.
export async function specScoreboardHandler(_req, res, body) {
  const cmd = body.show ? "+showscores" : "-showscores";
  const ok = await execCfgCommand(cmd);
  sendJson(
    res,
    ok ? 200 : 503,
    ok ? { ok, show: Boolean(body.show) } : { error: "cs2 not running" },
  );
}
