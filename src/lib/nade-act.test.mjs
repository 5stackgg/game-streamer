// node --test src/lib/nade-act.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";

import { nadeActKeys } from "./nade-act.mjs";

test("a standing left click is the default", () => {
  assert.deepEqual(nadeActKeys({ technique: "Stationary", strength: "Full" }), {
    press: "+attack",
    release: "-attack",
    after: "",
  });
  assert.deepEqual(nadeActKeys(), nadeActKeys({ strength: "Full" }));
});

test("throw strength picks the mouse buttons", () => {
  assert.equal(nadeActKeys({ strength: "Half" }).press, "+attack; +attack2");
  assert.equal(nadeActKeys({ strength: "Half" }).release, "-attack; -attack2");
  assert.equal(nadeActKeys({ strength: "Drop" }).press, "+attack2");
});

test("a jump throw jumps on the same frame the grenade is let go", () => {
  const keys = nadeActKeys({ technique: "Jump", strength: "Full" });

  assert.equal(keys.release, "+jump; -attack");
  assert.equal(keys.after, "-jump");
});

test("a jump-throw bind jumps whatever the technique says", () => {
  assert.equal(
    nadeActKeys({ technique: "Stationary", jumpBind: true }).release,
    "+jump; -attack",
  );
});

test("a crouch throw is crouched before the pin comes out", () => {
  const keys = nadeActKeys({ technique: "CrouchJump", strength: "Drop" });

  assert.equal(keys.press, "+duck; +attack2");
  assert.equal(keys.release, "+jump; -attack2");
  assert.equal(keys.after, "-jump; -duck");
});
