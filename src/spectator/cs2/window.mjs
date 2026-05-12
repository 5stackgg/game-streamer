import { DISPLAY } from "../env.mjs";
import { run } from "../util/run.mjs";

// cs2's reported window name varies by game state, so we try several
// strategies. xdotool --name matches per-property, so anchored ^...$
// forms miss when WM_NAME differs from _NET_WM_NAME. Returns null
// silently — callers check the return value.
export async function findCs2Window() {
  for (const pattern of ["Counter-Strike 2", "Counter-Strike", "cs2"]) {
    const r = await run(["xdotool", "search", "--name", pattern]);
    if (r.code === 0) {
      const ids = r.stdout.trim().split("\n").filter(Boolean);
      if (ids.length) return ids[0];
    }
  }
  const byClass = await run(["xdotool", "search", "--class", "cs2"]);
  if (byClass.code === 0) {
    const ids = byClass.stdout.trim().split("\n").filter(Boolean);
    if (ids.length) return ids[0];
  }
  const tree = await run(["xwininfo", "-display", DISPLAY, "-root", "-tree"]);
  if (tree.code === 0) {
    for (const line of tree.stdout.split("\n")) {
      if (line.includes('"Counter-Strike 2"')) {
        const id = line.trim().split(/\s+/)[0];
        if (id?.startsWith("0x")) return id;
      }
    }
  }
  return null;
}
