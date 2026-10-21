// node --test src/flows/switch-match.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, closeSync, existsSync, mkdirSync, mkdtempSync, openSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import process from "node:process";
import { setTimeout as sleep } from "node:timers/promises";

const FLOWS_DIR = dirname(new URL(import.meta.url).pathname);
const LIB_DIR = join(FLOWS_DIR, "..", "lib");

// The api records every call's url and x-origin-auth and answers 204, a frame grab
// writes a file, and no HUD is running.
const STUBS = {
  curl: `#!/usr/bin/env bash
auth="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) case "$2" in x-origin-auth:*) auth="\${2#x-origin-auth: }" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
printf '%s\\t%s\\n' "$url" "$auth" >>"$CALLS"
printf '204'
`,
  "gst-launch-1.0": `#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in location=*) printf 'jpg' >"\${a#location=}" ;; esac
done
`,
  pgrep: "#!/usr/bin/env bash\nexit 1\n",
};

function pod() {
  const root = mkdtempSync(join(tmpdir(), "switch-match-flow-"));
  const bin = join(root, "bin");
  mkdirSync(bin);
  for (const [name, body] of Object.entries(STUBS)) {
    writeFileSync(join(bin, name), body);
    chmodSync(join(bin, name), 0o755);
  }
  const logDir = join(root, "log");
  const env = {
    ...process.env,
    PATH: `${bin}:${process.env.PATH}`,
    LOG_DIR: logDir,
    XDG_RUNTIME_DIR: join(root, "xdg"),
    STEAM_LIBRARY: join(root, "steam"),
    STATUS_API_BASE: "http://api.test",
    MEDIAMTX_SRT_BASE: "srt://mediamtx.test:8890",
    STATUS_POLL_SECONDS: "1",
    SNAPSHOT_INTERVAL_SECONDS: "1",
    SNAPSHOT_BOOT_INTERVAL_SECONDS: "1",
    CALLS: join(root, "calls"),
    OUT: join(root, "out"),
  };
  return { root, logDir, env };
}

// Output goes to a file: the daemons a script starts keep its stdout and stderr open.
function bash(script, env) {
  const out = openSync(env.OUT, "a");
  try {
    const r = spawnSync("bash", ["-c", script], { env, stdio: ["ignore", out, out] });
    assert.equal(r.status, 0, readFileSync(env.OUT, "utf8"));
    return r;
  } finally {
    closeSync(out);
  }
}

function calls({ env }) {
  if (!existsSync(env.CALLS)) {
    return [];
  }
  return readFileSync(env.CALLS, "utf8").split("\n").filter(Boolean).map((line) => line.split("\t"));
}

function snapshots(pod, matchId) {
  return calls(pod).filter(([url]) => url === `http://api.test/game-streamer/${matchId}/snapshot`);
}

async function until(check, what) {
  for (let i = 0; i < 100; i++) {
    if (check()) {
      return;
    }
    await sleep(50);
  }
  assert.fail(`timed out waiting for ${what}`);
}

// The daemons the flow leaves behind outlive it, as they do on a pod.
function stopDaemons({ logDir }) {
  for (const file of ["snapshot.pid", "status.daemon.pid"]) {
    const path = join(logDir, file);
    if (existsSync(path)) {
      try {
        process.kill(Number(readFileSync(path, "utf8")));
      } catch {
        // already gone
      }
    }
  }
}

function switchTo(pod, env) {
  return bash(`bash "${join(FLOWS_DIR, "switch-match.sh")}"`, { ...pod.env, MODE: "live", ...env });
}

test("thumbnails follow the switch: uploaded as the new match, never again as the old one", async () => {
  const p = pod();
  try {
    bash(`. "${join(LIB_DIR, "snapshot.sh")}"; start_snapshot_loop`, {
      ...p.env,
      MATCH_ID: "match-a",
      MATCH_PASSWORD: "password-a",
    });
    await until(() => snapshots(p, "match-a").length > 0, "a snapshot as match-a");

    switchTo(p, {
      MATCH_ID: "match-b",
      MATCH_PASSWORD: "password-b",
      OLD_MATCH_ID: "match-a",
      STREAM_ID: "match-a",
    });
    await sleep(300);
    const asA = snapshots(p, "match-a").length;
    await until(() => snapshots(p, "match-b").length >= 2, "two snapshots as match-b");

    assert.equal(snapshots(p, "match-a").length, asA);
    assert.deepEqual([...new Set(snapshots(p, "match-b").map(([, auth]) => auth))], ["match-b:password-b"]);
  } finally {
    stopDaemons(p);
  }
});
