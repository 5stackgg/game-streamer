// node --test src/flows/run-nades.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = readFileSync(new URL("./run-nades.sh", import.meta.url), "utf8");

function fn(name) {
  const m = SCRIPT.match(new RegExp(`^${name}\\(\\) \\{\\n[\\s\\S]*?^\\}$`, "m"));
  assert.ok(m, `${name}() not found in run-nades.sh`);
  return m[0];
}

// The whole flow needs Steam and a GPU, so this runs only the launch, with the
// launcher recording the arguments cs2 would get.
function cs2LaunchArgs() {
  const args = join(mkdtempSync(join(tmpdir(), "run-nades-")), "args");
  const r = spawnSync("bash", ["-c", `
export_cs2_shader_cache_env() { :; }
compute_cpu_split() { :; }
cs2_cpu_pin() { :; }
log() { :; }
spawn_logged() { shift; printf '%s\\n' "$@" >"$ARGS"; }
${fn("do_applaunch")}
do_applaunch
`], {
    encoding: "utf8",
    env: { ...process.env, ARGS: args, STEAM_HOME: "/steam", CS2_WIDTH: "1280", CS2_HEIGHT: "720", CS2_FPS_MAX: "120" },
  });
  assert.equal(r.status, 0, r.stderr);
  return readFileSync(args, "utf8").split("\n").filter(Boolean);
}

// The reconnect types `disconnect` and `exec` into the console, and its toggle
// assumes the console starts closed.
test("cs2 launches with its console closed, still logging it and still able to open it", () => {
  const args = cs2LaunchArgs();
  assert.ok(!args.includes("-console"), args.join(" "));
  assert.ok(args.includes("-condebug"), args.join(" "));
  const autoexec = SCRIPT.match(/cat > "\$CS2_CFG_DIR\/nade_autoexec\.cfg" <<EOF\n([\s\S]*?)\nEOF/);
  assert.ok(autoexec, "nade_autoexec.cfg not found in run-nades.sh");
  assert.match(autoexec[1], /^con_enable 1$/m);
});

// The account's saved config can load after the autoexec and turn the console
// off, and nade_view.cfg is what every lineup re-runs in game.
test("every lineup's in-game cfg turns the console back on", () => {
  const view = SCRIPT.match(/read -r -d '' NADE_VIEW_CMDS <<'EOF' \|\| true\n([\s\S]*?)\nEOF/);
  assert.ok(view, "NADE_VIEW_CMDS not found in run-nades.sh");
  assert.match(view[1], /^con_enable 1$/m);
  assert.match(SCRIPT, /printf '%s\\n' "\$NADE_VIEW_CMDS" > "\$CS2_CFG_DIR\/nade_view\.cfg"/);
});
