// node --test src/lib/batch-nades.test.mjs
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

const LIB_DIR = dirname(new URL(import.meta.url).pathname);
const SPEC = "http://spec.invalid";
const ADDR = "127.0.0.1:27015";
const PASSWORD = 'pa"ss\\';

// /nade/self answers $STUB_SELF; every POST is recorded with its body and answered
// $STUB_CODE.
const CURL_STUB = `#!/usr/bin/env bash
url="\${*: -1}"
case "$url" in
  */nade/self) printf '%s' "$STUB_SELF"; exit 0 ;;
esac
body="" format="" fail=0 quiet=0
while [ $# -gt 0 ]; do
  case "$1" in
    --data|--data-binary) body="$2"; [ "$body" = @- ] && body=$(cat); shift ;;
    --write-out) format="$2"; shift ;;
    --output) quiet=1; shift ;;
    --fail) fail=1 ;;
  esac
  shift
done
printf '%s\\t%s\\n' "\${url#"$SPEC"}" "$body" >>"$POSTS"
[ "$quiet" = 1 ] || printf '{"error":"stub"}'
[ -z "$format" ] || printf "\${format//%\\{http_code\\}/$STUB_CODE}"
[ "$STUB_CODE" = 000 ] && exit 7
[ "$fail" = 1 ] && [ "$STUB_CODE" -ge 400 ] && exit 22
exit 0
`;

// batch-nades.sh runs after common.sh, which is where spec_curl comes from.
const SPEC_CURL = readFileSync(join(LIB_DIR, "common.sh"), "utf8").match(/^spec_curl\(\) \{\n[\s\S]*?^\}$/m)[0];

const dirs = [];
after(() => {
  for (const dir of dirs) {
    rmSync(dir, { recursive: true, force: true });
  }
});

// Runs `script` with batch-nades.sh sourced against a console log that holds `consoleLog`.
function run(script, { consoleLog = "", self = "-1||||" } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "batch-nades-"));
  dirs.push(dir);
  writeFileSync(join(dir, "curl"), CURL_STUB);
  chmodSync(join(dir, "curl"), 0o755);
  writeFileSync(join(dir, "console.log"), consoleLog);
  const posts = join(dir, "posts");
  const r = spawnSync(
    "bash",
    ["-c", `${SPEC_CURL}\nsay() { printf '%s\\n' "$*" >&2; }\n. "$LIB_DIR/batch-nades.sh"\n${script}`],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${dir}:${process.env.PATH}`,
        LIB_DIR,
        SPEC,
        SPEC_SERVER_URL: SPEC,
        CS2_CONSOLE_LOG: join(dir, "console.log"),
        CS2_CONNECT_ADDR: ADDR,
        CS2_CONNECT_PASSWORD: PASSWORD,
        STUB_SELF: self,
        STUB_CODE: "200",
        POSTS: posts,
      },
    },
  );
  assert.equal(r.status, 0, r.stderr);
  const sent = existsSync(posts)
    ? readFileSync(posts, "utf8").split("\n").filter(Boolean).map((line) => {
        const [path, body] = line.split("\t");
        try {
          return [path, JSON.parse(body)];
        } catch {
          return [path, body];
        }
      })
    : [];
  return { sent, log: r.stderr, stdout: r.stdout };
}

const RECONNECT = ["/nade/reconnect", { addr: ADDR, password: PASSWORD }];
const DROPPED = "Disconnect: NETWORK_DISCONNECT_OVERFLOW\n";

test("a dropped client is reconnected through the spec-server's connect route, password and all", () => {
  const { sent } = run("nade_reconnect_if_dropped", { consoleLog: DROPPED });
  assert.deepEqual(sent, [RECONNECT]);
});

test("a client that never sent GSI is reconnected through the same route", () => {
  const { sent } = run("nade_reconnect");
  assert.deepEqual(sent, [RECONNECT]);
});

test("a dropped client's reconnect the spec-server refuses is retried next pass, and is not one of its reconnects", () => {
  const { sent, log, stdout } = run(`
    export STUB_CODE=503
    nade_reconnect_if_dropped
    nade_reconnect_if_dropped
    export STUB_CODE=200
    nade_reconnect_if_dropped
    nade_reconnect_if_dropped
    echo "$NADE_DROP_RECONNECTS"
  `, { consoleLog: DROPPED });
  assert.deepEqual(sent, [RECONNECT, RECONNECT, RECONNECT]);
  assert.equal(stdout.trim(), "1");
  assert.match(log, /spec-server answered 503/);
});

test("a refused reconnect for a client that never sent GSI does not use up an attempt", () => {
  const { sent, stdout } = run(`
    export STUB_CODE=503
    nade_reconnect
    nade_reconnect
    export STUB_CODE=200
    nade_reconnect
    nade_reconnect
    nade_reconnect
    echo "$NADE_RECONNECT_ATTEMPTS"
  `);
  assert.deepEqual(sent, [RECONNECT, RECONNECT, RECONNECT, RECONNECT]);
  assert.equal(stdout.trim(), "2");
});

test("a spec-server that never answers still counts the reconnect, in case it lands late", () => {
  const { sent, stdout } = run(`
    export STUB_CODE=000
    nade_reconnect
    nade_reconnect
    nade_reconnect
    echo "$NADE_RECONNECT_ATTEMPTS"
  `);
  assert.deepEqual(sent, [RECONNECT, RECONNECT]);
  assert.equal(stdout.trim(), "2");
});
