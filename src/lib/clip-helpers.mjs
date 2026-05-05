#!/usr/bin/env node
// CLI helpers used by batch-highlights.sh and inline-clip-render.sh in
// place of inline `python3 -c '...'` blocks. All variable values flow
// via argv (never interpolated into source), so player names with
// quotes / backslashes / regex metachars don't break parsing or escape
// into the running script.
//
// Each subcommand reads JSON from stdin (when applicable) and writes
// the extracted value as a plain string to stdout. Empty stdout is the
// canonical "missing" signal for the bash callers.
//
// Usage: node clip-helpers.mjs <subcommand> [args...]

import { readFileSync } from "node:fs";

function readStdinJson() {
  try {
    return JSON.parse(readFileSync(0, "utf8"));
  } catch {
    return null;
  }
}

const STEAMID64_BASE = 76561197960265728n;
const subcmd = process.argv[2];
const args = process.argv.slice(3);

switch (subcmd) {
  // [stdin: /demo/state] -> name of the player whose steam_id matches
  // argv[0], from gsi.spec_slots. Empty when missing.
  case "name-for-steamid": {
    const sid = args[0] ?? "";
    const d = readStdinJson();
    const slots = d?.gsi?.spec_slots ?? [];
    const m = slots.find((s) => s?.steam_id === sid);
    process.stdout.write(typeof m?.name === "string" ? m.name : "");
    break;
  }

  // [stdin: /demo/state] -> slot number (1..12) for argv[0] steam_id.
  case "slot-for-steamid": {
    const sid = args[0] ?? "";
    const d = readStdinJson();
    const slots = d?.gsi?.spec_slots ?? [];
    const m = slots.find((s) => s?.steam_id === sid);
    process.stdout.write(typeof m?.slot === "number" ? String(m.slot) : "");
    break;
  }

  // [stdin: /demo/state] -> gsi.spectated_steam_id, or empty.
  case "spectated-steamid": {
    const d = readStdinJson();
    const sid = d?.gsi?.spectated_steam_id;
    process.stdout.write(typeof sid === "string" ? sid : "");
    break;
  }

  // [stdin: /demo/state] -> "1" if gsi.demoui_hidden truthy, else "0".
  case "demoui-hidden": {
    const d = readStdinJson();
    process.stdout.write(d?.gsi?.demoui_hidden ? "1" : "0");
    break;
  }

  // [stdin: /demo/state] -> tick (or "?" if missing).
  case "state-tick": {
    const d = readStdinJson();
    process.stdout.write(typeof d?.tick === "number" ? String(d.tick) : "?");
    break;
  }

  // [stdin: /demo/state] -> "true" | "false" | "?"
  case "state-paused": {
    const d = readStdinJson();
    if (d?.paused === true) process.stdout.write("true");
    else if (d?.paused === false) process.stdout.write("false");
    else process.stdout.write("?");
    break;
  }

  // [stdin: title] -> rewrite leading "Player NNNN" prefix to argv[0].
  // Uses a function callback for the replacement so $1/$&/$$ in the
  // resolved name aren't interpreted as backreferences.
  case "patch-player-name": {
    const newName = args[0] ?? "";
    const title = readFileSync(0, "utf8");
    process.stdout.write(
      title.replace(/^Player [A-Za-z0-9_-]+/, () => newName),
    );
    break;
  }

  // [stdin: clip-render status JSON] -> .status field, or empty.
  case "status-field": {
    const d = readStdinJson();
    process.stdout.write(typeof d?.status === "string" ? d.status : "");
    break;
  }

  // [stdin: CLIP_BATCH_JOBS] -> number of jobs (0 if not an array).
  case "jobs-count": {
    const d = readStdinJson();
    process.stdout.write(String(Array.isArray(d) ? d.length : 0));
    break;
  }

  // [stdin: CLIP_BATCH_JOBS] -> JSON of jobs[argv[0]]. Exits 1 if oob.
  case "jobs-at": {
    const idx = Number(args[0]);
    const d = readStdinJson();
    if (!Array.isArray(d) || !Number.isFinite(idx) || idx < 0 || idx >= d.length) {
      process.exit(1);
    }
    process.stdout.write(JSON.stringify(d[idx]));
    break;
  }

  // [stdin: job_json] -> top-level job_id.
  case "job-id": {
    const d = readStdinJson();
    process.stdout.write(typeof d?.job_id === "string" ? d.job_id : "");
    break;
  }

  // [stdin: job_json] -> top-level token.
  case "job-token": {
    const d = readStdinJson();
    process.stdout.write(typeof d?.token === "string" ? d.token : "");
    break;
  }

  // [stdin: job_json] -> spec.title (or empty).
  case "job-title": {
    const d = readStdinJson();
    const t = d?.spec?.title;
    process.stdout.write(typeof t === "string" ? t : "");
    break;
  }

  // [stdin: job_json] -> spec.segments as a JSON string.
  case "job-segments": {
    const d = readStdinJson();
    const segs = d?.spec?.segments;
    process.stdout.write(JSON.stringify(Array.isArray(segs) ? segs : []));
    break;
  }

  // [stdin: job_json] -> "1280x720" | "1920x1080" from spec.output.resolution.
  case "job-output-dims": {
    const d = readStdinJson();
    const res = d?.spec?.output?.resolution ?? "1080p";
    process.stdout.write(res === "720p" ? "1280x720" : "1920x1080");
    break;
  }

  // [stdin: job_json] -> spec.output.fps (default 60).
  case "job-output-fps": {
    const d = readStdinJson();
    const raw = d?.spec?.output?.fps;
    const fps = parseInt(raw, 10);
    process.stdout.write(String(Number.isFinite(fps) ? fps : 60));
    break;
  }

  // [stdin: job_json] -> first segment's pov_steam_id (or empty).
  case "job-first-pov-steamid": {
    const d = readStdinJson();
    const seg = (d?.spec?.segments ?? [])[0];
    const sid = seg?.pov_steam_id;
    process.stdout.write(typeof sid === "string" ? sid : "");
    break;
  }

  // [stdin: CLIP_SEGMENTS] -> number of segments.
  case "segs-count": {
    const d = readStdinJson();
    process.stdout.write(String(Array.isArray(d) ? d.length : 0));
    break;
  }

  // [stdin: CLIP_SEGMENTS] -> sum of (end_tick - start_tick) >=0.
  case "segs-total-ticks": {
    const d = readStdinJson();
    let total = 0;
    if (Array.isArray(d)) {
      for (const s of d) {
        const start = Number(s?.start_tick);
        const end = Number(s?.end_tick);
        if (Number.isFinite(start) && Number.isFinite(end)) {
          total += Math.max(0, end - start);
        }
      }
    }
    process.stdout.write(String(total));
    break;
  }

  // [stdin: CLIP_SEGMENTS] -> segments[argv[0]].start_tick (or empty).
  case "seg-start-tick": {
    const idx = Number(args[0]);
    const d = readStdinJson();
    const v = Array.isArray(d) ? d[idx]?.start_tick : null;
    process.stdout.write(typeof v === "number" ? String(v) : "");
    break;
  }

  // [stdin: CLIP_SEGMENTS] -> segments[argv[0]].end_tick (or empty).
  case "seg-end-tick": {
    const idx = Number(args[0]);
    const d = readStdinJson();
    const v = Array.isArray(d) ? d[idx]?.end_tick : null;
    process.stdout.write(typeof v === "number" ? String(v) : "");
    break;
  }

  // [stdin: CLIP_SEGMENTS] -> accountid for segments[argv[0]].pov_steam_id
  // (steamid64 - 76561197960265728), or empty if missing/invalid.
  case "seg-pov-accountid": {
    const idx = Number(args[0]);
    const d = readStdinJson();
    const sid = Array.isArray(d) ? d[idx]?.pov_steam_id : null;
    if (typeof sid !== "string" || !/^\d+$/.test(sid)) {
      process.stdout.write("");
      break;
    }
    const aid = BigInt(sid) - STEAMID64_BASE;
    process.stdout.write(aid > 0n ? aid.toString() : "");
    break;
  }

  // Build a status-body JSON object from "k=v" args. `progress` is
  // coerced to a number (and dropped if NaN); other keys stay strings.
  case "status-body": {
    const out = {};
    for (const kv of args) {
      const i = kv.indexOf("=");
      if (i < 0) continue;
      const k = kv.slice(0, i);
      const v = kv.slice(i + 1);
      if (k === "progress") {
        const f = Number(v);
        if (Number.isFinite(f)) out[k] = f;
      } else {
        out[k] = v;
      }
    }
    process.stdout.write(JSON.stringify(out));
    break;
  }

  default:
    process.stderr.write(`clip-helpers: unknown subcommand: ${subcmd}\n`);
    process.exit(2);
}
