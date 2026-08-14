import process from "node:process";

import { run } from "../util/run.mjs";
import { findCs2Window } from "./window.mjs";

// XTest keystrokes land on whatever currently holds X input focus -- xdotool's
// `--window` (XSendEvent) is filtered by cs2 and dropped, so targeting is not
// an option. That makes the whole spectator input path silently no-op if
// anything takes focus away from cs2, which is easy on this display: there is
// no window manager, only a compositor, so destroying the focused window (a
// steam dialog, the webhelper being reaped) leaves focus unset rather than
// reassigning it, and every key after that goes nowhere.
//
// So re-point focus at cs2 before sending. windowfocus is XSetInputFocus and
// does NOT restack -- unlike windowactivate, which would raise cs2 above the
// HUD overlay and break compositing.
let lastFocusWarning = "";

async function focusCs2(win) {
  const current = await run(["xdotool", "getwindowfocus"]);
  const focused = current.code === 0 ? current.stdout.trim() : "";

  if (focused === win) {
    lastFocusWarning = "";
    return;
  }

  // Logged once per distinct value: a persistent thief would otherwise write a
  // line for every key we send.
  if (lastFocusWarning !== focused) {
    lastFocusWarning = focused;
    process.stderr.write(
      `[spec-input] focus was ${focused || "unset"}, expected cs2 ${win} — re-pointing\n`,
    );
  }

  await run(["xdotool", "windowfocus", "--sync", win]);
}

export async function focusState() {
  const win = await findCs2Window();
  const current = await run(["xdotool", "getwindowfocus"]);
  const focused = current.code === 0 ? current.stdout.trim() : null;

  let focusedName = null;
  if (focused) {
    const name = await run(["xdotool", "getwindowname", focused]);
    focusedName = name.code === 0 ? name.stdout.trim() : null;
  }

  return {
    cs2_window: win,
    focused_window: focused,
    focused_name: focusedName,
    cs2_has_focus: win !== null && focused === win,
  };
}

export async function sendKey(key) {
  const win = await findCs2Window();

  if (win === null) {
    return false;
  }

  await focusCs2(win);
  await run(["xdotool", "key", "--clearmodifiers", key]);
  return true;
}

export async function sendConsoleCommand(cmd) {
  const win = await findCs2Window();

  if (win === null) {
    return false;
  }

  await focusCs2(win);
  await run(["xdotool", "key", "--clearmodifiers", "grave"]);
  await new Promise((r) => setTimeout(r, 80));
  await run(["xdotool", "type", "--delay", "20", cmd]);
  await new Promise((r) => setTimeout(r, 40));
  await run(["xdotool", "key", "--clearmodifiers", "Return"]);
  await new Promise((r) => setTimeout(r, 60));
  await run(["xdotool", "key", "--clearmodifiers", "grave"]);
  return true;
}
