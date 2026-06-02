// Find the Steam-blue "Play anyway" button in a raw RGBA frame, but only if the
// region looks like a modal (dimmed dark overlay) — so a bright live store can't
// match. Usage: node find-cloud-button.mjs <raw> <width> <height>
// Prints "cx cy w h count" if confirmed, else nothing (caller must not click).
import { readFileSync } from 'node:fs';

const [, , file, wArg, hArg] = process.argv;
const W = +wArg, H = +hArg;
const buf = readFileSync(file);

let minX = W, minY = H, maxX = -1, maxY = -1, blue = 0, sx = 0, sy = 0, dark = 0;
for (let y = 0; y < H; y++) {
  for (let x = 0; x < W; x++) {
    const i = (y * W + x) * 4;
    const r = buf[i], g = buf[i + 1], b = buf[i + 2];
    if (r < 80 && g < 80 && b < 80) dark++;
    if (b > 180 && r < 130 && b - r > 90 && g > 80 && g < 210) {
      blue++; sx += x; sy += y;
      if (x < minX) minX = x; if (x > maxX) maxX = x;
      if (y < minY) minY = y; if (y > maxY) maxY = y;
    }
  }
}

// Not a dimmed modal overlay (e.g. the live store is bright) → refuse.
if (dark / (W * H) < 0.45) process.exit(0);
if (blue < 150) process.exit(0);

const bw = maxX - minX + 1, bh = maxY - minY + 1;
// Reject scattered or region-filling matches (not a single button).
if (bw < 30 || bw > W * 0.7 || bh < 12 || bh > H * 0.4) process.exit(0);

process.stdout.write(`${Math.round(sx / blue)} ${Math.round(sy / blue)} ${bw} ${bh} ${blue}\n`);
