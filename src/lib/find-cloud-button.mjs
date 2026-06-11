// Find the Steam-blue "Play anyway" button in a raw RGBA frame, but only if the
// region looks like a modal (dimmed dark overlay) — so a bright live store can't
// match. The modal's full-width blue TOP BORDER matches the same colour, so we
// cluster by row-bands and keep only button-shaped ones (border is ~2-3px tall).
// Usage: node find-cloud-button.mjs <raw> <width> <height>
// Prints "cx cy w h count" if confirmed, else nothing (caller must not click).
import { readFileSync } from 'node:fs';

const [, , file, wArg, hArg] = process.argv;
const W = +wArg, H = +hArg;
const buf = readFileSync(file);

const isBlue = (r, g, b) => b > 180 && r < 130 && b - r > 90 && g > 80 && g < 210;

let dark = 0;
const rowBlue = new Int32Array(H);
for (let y = 0; y < H; y++) {
  for (let x = 0; x < W; x++) {
    const i = (y * W + x) * 4;
    const r = buf[i], g = buf[i + 1], b = buf[i + 2];
    if (r < 80 && g < 80 && b < 80) dark++;
    if (isBlue(r, g, b)) rowBlue[y]++;
  }
}

const darkFrac = dark / (W * H);
const dbg = process.env.CLOUD_BTN_DEBUG
  ? (m) => console.error(`debug: ${m}`)
  : () => {};
dbg(`dark_frac=${darkFrac.toFixed(2)} (need>=0.45) blue_total=${rowBlue.reduce((a, c) => a + c, 0)}`);

// Not a dimmed modal overlay (e.g. the live store is bright) → refuse.
if (darkFrac < 0.45) process.exit(0);

// Contiguous bands of rows with >=20 blue px; keep button-shaped bands only.
let best = null;
for (let y = 0; y < H; y++) {
  if (rowBlue[y] < 20) continue;
  let y2 = y;
  while (y2 + 1 < H && rowBlue[y2 + 1] >= 20) y2++;
  const bh = y2 - y + 1;
  let count = 0;
  for (let yy = y; yy <= y2; yy++) count += rowBlue[yy];
  dbg(`band y=${y}..${y2} h=${bh} blue=${count}`);
  if (bh >= 12 && bh <= H * 0.4 && count >= 150 && (!best || count > best.count)) {
    best = { y1: y, y2, count };
  }
  y = y2;
}
if (!best) process.exit(0);

// Bbox + centroid of blue pixels inside the winning band.
let minX = W, maxX = -1, sx = 0, sy = 0;
for (let y = best.y1; y <= best.y2; y++) {
  for (let x = 0; x < W; x++) {
    const i = (y * W + x) * 4;
    if (isBlue(buf[i], buf[i + 1], buf[i + 2])) {
      sx += x; sy += y;
      if (x < minX) minX = x; if (x > maxX) maxX = x;
    }
  }
}
const bw = maxX - minX + 1, bh = best.y2 - best.y1 + 1;
dbg(`best band bbox=${bw}x${bh} centroid=${Math.round(sx / best.count)},${Math.round(sy / best.count)}`);
if (bw < 30 || bw > W * 0.7) process.exit(0);

process.stdout.write(`${Math.round(sx / best.count)} ${Math.round(sy / best.count)} ${bw} ${bh} ${best.count}\n`);
