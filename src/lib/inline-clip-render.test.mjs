// node --test src/lib/inline-clip-render.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = readFileSync(new URL("./inline-clip-render.sh", import.meta.url), "utf8");

// The whole script needs cs2 and a GPU, so these run its own text for the exit trap
// and for everything after the segments are concatenated, with the api, ffmpeg and
// the playback calls stubbed.
function fn(name) {
  const m = SCRIPT.match(new RegExp(`^${name}\\(\\) \\{\\n[\\s\\S]*?^\\}$`, "m"));
  assert.ok(m, `${name}() not found in inline-clip-render.sh`);
  return m[0];
}

function tail() {
  const i = SCRIPT.indexOf('\nrm -rf "$SEG_DIR"\n');
  assert.ok(i >= 0, "post-concat cleanup not found in inline-clip-render.sh");
  return SCRIPT.slice(i + 1);
}

function scratch() {
  const root = mkdtempSync(join(tmpdir(), "inline-clip-render-"));
  const clips = join(root, "clips");
  const bin = join(root, "bin");
  mkdirSync(clips);
  mkdirSync(bin);
  const files = {
    segDir: join(clips, "job.segs"),
    chipMov: join(clips, "job-chip.mov"),
    outFile: join(clips, "job.mp4"),
  };
  mkdirSync(files.segDir);
  writeFileSync(join(files.segDir, "seg-000.mp4"), "segment");
  writeFileSync(files.chipMov, "chip");
  writeFileSync(files.outFile, "clip");
  for (const [tool, rc] of [["curl", "${CURL_RC:-0}"], ["ffmpeg", "1"], ["ffprobe", "1"]]) {
    writeFileSync(join(bin, tool), `#!/usr/bin/env bash\nexit ${rc}\n`);
    chmodSync(join(bin, tool), 0o755);
  }
  return { bin, files };
}

function runBash(body, { bin, files }, env = {}) {
  const harness = `set -uo pipefail
say() { :; }
api_status() { :; }
api_progress_settle() { :; }
restart_capture() { :; }
restore_user_playback() { :; }
stop_capture_diag() { :; }
parse_upload_progress() { cat >/dev/null; }
${fn("die_failed")}
CLIP_RENDER_JOB_ID=job
CLIP_RENDER_TOKEN=token
STATUS_API_BASE=http://api.invalid
LIVE_CAPTURE_STOPPED=0
TOTAL_DURATION_TICKS=640
SEG_DIR='${files.segDir}'
CHIP_MOV='${files.chipMov}'
CLIP_OUT_FILE='${files.outFile}'
CLIP_THUMB_FILE='${files.outFile}.jpg'
${body}
`;
  return spawnSync("bash", ["-c", harness], {
    encoding: "utf8",
    env: { ...process.env, ...env, PATH: `${bin}:${process.env.PATH}` },
  });
}

function leftovers({ files }) {
  return Object.values(files).filter((path) => existsSync(path));
}

test("a render that dies before upload leaves no segments, chip or partial clip behind", () => {
  const job = scratch();
  const r = runBash(`${fn("on_exit")}\ntrap on_exit EXIT\nexit 1`, job);
  assert.equal(r.status, 1, r.stderr);
  assert.deepEqual(leftovers(job), []);
});

test("an uploaded clip leaves no chip intermediate behind", () => {
  const job = scratch();
  const r = runBash(tail(), job);
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(leftovers(job), []);
});

test("a failed upload removes the rendered clip", () => {
  const job = scratch();
  const r = runBash(tail(), job, { CURL_RC: "7" });
  assert.equal(r.status, 1, r.stderr);
  assert.deepEqual(leftovers(job), []);
});

function montage(t) {
  const job = scratch();
  const root = join(job.files.segDir, "..");
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return job;
}

for (const [label, log, expected] of [
  ["keeps uniform GPU segments eligible", "normal encode warning", "1"],
  ["rejects mixed segments after a successful CPU retry", "WARN final encode: h264_nvenc failed, retrying libx264", "0"],
]) {
  test(`polish reaping ${label}`, (t) => {
    const job = montage(t);
    const r = runBash(`
COPY_ELIGIBLE=1
POLISH_BG_IDX=0
POLISH_BG_LOG="$SEG_DIR/polish.log"
printf '%s\\n' '${log}' > "$POLISH_BG_LOG"
( exit 0 ) & POLISH_BG_PID=$!
${fn("reap_polish_bg")}
reap_polish_bg
printf '%s|%s|%s' "$COPY_ELIGIBLE" "$POLISH_BG_PID" "$POLISH_BG_LOG"
`, job);
    assert.equal(r.status, 0, r.stderr);
    assert.equal(r.stdout, `${expected}||`);
    assert.equal(existsSync(join(job.files.segDir, "polish.log")), false);
  });
}

test("a failed background polish still fails the render", (t) => {
  const job = montage(t);
  const r = runBash(`
POLISH_BG_IDX=0
POLISH_BG_LOG="$SEG_DIR/polish.log"
: > "$POLISH_BG_LOG"
( exit 7 ) & POLISH_BG_PID=$!
${fn("reap_polish_bg")}
reap_polish_bg
`, job);
  assert.equal(r.status, 1, r.stderr);
  assert.equal(existsSync(join(job.files.segDir, "polish.log")), false);
});

function runConcat(t, mode, cached = false) {
  const job = montage(t);
  const r = runBash(`
OUTRO_FILE="$SEG_DIR/outro.mp4"
OUTRO_CACHE_DIR="$SEG_DIR/cache"
mkdir -p "$OUTRO_CACHE_DIR"
printf 'outro' > "$OUTRO_FILE"
printf "file '%s'\\nfile '%s'\\n" "$SEG_DIR/seg-000.mp4" "$OUTRO_FILE" > "$SEG_DIR/concat.txt"
WILL_FUSE_POLISH_OUTRO=0
COPY_ELIGIBLE=1
FFMPEG_VENC_ARGS=(-c:v h264_nvenc)
matched_outro_cache_path() { printf '%s/matched.mp4' "$OUTRO_CACHE_DIR"; }
has_audio_stream() { return 0; }
ffmpeg_venc() {
  printf 'call\\n' >> "$SEG_DIR/transcode.calls"
  printf 'transcoded' > "\${!#}"
  ${mode === "retry" ? "FFMPEG_VENC_ARGS=(-c:v libx264)" : ":"}
  ${mode === "failed" ? "return 1" : "return 0"}
}
ffmpeg() { printf 'copy\\n' >> "$SEG_DIR/copy.calls"; printf 'clip' > "\${!#}"; }
ffprobe() { if [ "\${!#}" = "$CLIP_OUT_FILE" ]; then echo 2; else echo 1; fi; }
${cached ? "printf cached > \"$(matched_outro_cache_path)\"" : ":"}
${fn("try_concat_copy")}
rc=0; try_concat_copy || rc=$?
cache=0; [ ! -s "$(matched_outro_cache_path)" ] || cache=1
copy=0; [ ! -f "$SEG_DIR/copy.calls" ] || copy=1
transcode=0; [ ! -f "$SEG_DIR/transcode.calls" ] || transcode=1
staging=0; for f in "$OUTRO_CACHE_DIR"/*.tmp; do [ ! -f "$f" ] || staging=1; done
printf '%s|%s|%s|%s|%s' "$rc" "$cache" "$copy" "$transcode" "$staging"
`, job);
  assert.equal(r.status, 0, r.stderr);
  return r.stdout;
}

test("a normal GPU outro is cached and stream-copied", (t) => {
  assert.equal(runConcat(t, "gpu"), "0|1|1|1|0");
});

test("a CPU retry of the outro neither caches nor stream-copies it", (t) => {
  assert.equal(runConcat(t, "retry"), "1|0|0|1|0");
});

test("a failed outro transcode removes its staging file", (t) => {
  assert.equal(runConcat(t, "failed"), "1|0|0|1|0");
});

test("a previously matched outro keeps the cache fast path", (t) => {
  assert.equal(runConcat(t, "gpu", true), "0|1|1|0|0");
});
