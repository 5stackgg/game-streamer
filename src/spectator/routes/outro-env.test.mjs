// node --test src/spectator/routes/outro-env.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import { filterOutroEnv } from "./outro-env.mjs";

const ORIGIN = "https://s3.example.com";
const KEY = `${ORIGIN}/demos/branding/outro_v1_1920x1080_60.mp4`;
// The two shapes the api sends: a cached outro (hit) and a render (miss).
const HIT = { CLIP_OUTRO_URL: `${KEY}?X-Amz-Signature=get` };
const MISS = {
  CLIP_OUTRO_RENDER: "1",
  CLIP_OUTRO_PUT_URL: `${KEY}?X-Amz-Signature=put`,
  CLIP_BRAND_LOGO_URL: `${ORIGIN}/demos/branding/logo.png?X-Amz-Signature=logo`,
  CLIP_BRAND_NAME: "",
  CLIP_BRAND_ACCENT: "33 94% 58%",
};
const ELSEWHERE = "http://10.0.0.1:9000/x.png";
// Node reads this as a path at ORIGIN (so its origin passes), curl as the host
// after the "@": it is not the URL as Node serializes it.
const SMUGGLED = `${ORIGIN}\\@10.0.0.1:9000/outro_v1_1920x1080_60.mp4?s=1`;

// The outro env the render gets for this outro_env.
const envFor = (src, origin = ORIGIN) => filterOutroEnv(src, origin).env;

test("passes a valid hit and a valid miss unchanged", () => {
  assert.deepEqual(filterOutroEnv(HIT, ORIGIN), { env: HIT, dropped: null });
  assert.deepEqual(filterOutroEnv(MISS, ORIGIN), { env: MISS, dropped: null });
  assert.deepEqual(envFor({ ...MISS, CLIP_BRAND_NAME: "Adria" }), {
    ...MISS,
    CLIP_BRAND_NAME: "Adria",
  });
  // A presigned URL serializes to itself (the %2F in the credential and the
  // rest of the SigV4 query stay as they are) under both S3 addressings.
  const sigv4 =
    "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=k%2F20261002%2Feu-central-1%2Fs3%2Faws4_request&X-Amz-Date=20261002T120000Z&X-Amz-Expires=3600&X-Amz-SignedHeaders=host&X-Amz-Signature=0a1b&x-id=GetObject";
  for (const origin of [
    ORIGIN,
    "https://demos.s3.eu-central-1.amazonaws.com",
  ]) {
    const src = {
      CLIP_OUTRO_URL: `${origin}/branding/outro_v1_1920x1080_60.mp4?${sigv4}`,
    };
    assert.deepEqual(filterOutroEnv(src, origin), { env: src, dropped: null });
  }
});

test("drops a miss whose PUT or logo URL is not the S3 origin", () => {
  assert.deepEqual(envFor({ ...MISS, CLIP_OUTRO_PUT_URL: ELSEWHERE }), {});
  assert.deepEqual(envFor({ ...MISS, CLIP_OUTRO_PUT_URL: SMUGGLED }), {});
  assert.deepEqual(envFor({ ...MISS, CLIP_BRAND_LOGO_URL: ELSEWHERE }), {});
  assert.deepEqual(envFor({ ...MISS, CLIP_BRAND_LOGO_URL: "logo.png" }), {});
  assert.deepEqual(envFor({ ...MISS, CLIP_BRAND_LOGO_URL: "" }), {});
  // A valid hit does not carry a rejected render key through either.
  assert.deepEqual(
    envFor({ ...HIT, ...MISS, CLIP_OUTRO_PUT_URL: ELSEWHERE }),
    {},
  );
});

test("drops a hit whose URL is not the S3 origin", () => {
  assert.deepEqual(envFor({ CLIP_OUTRO_URL: ELSEWHERE }), {});
  // Same host, other scheme: another origin.
  assert.deepEqual(
    envFor({ CLIP_OUTRO_URL: "http://s3.example.com/x.mp4" }),
    {},
  );
  assert.deepEqual(envFor({ CLIP_OUTRO_URL: "" }), {});
  // The origin check alone passes these. Only the URL as Node serializes it
  // (new URL(v).href === v) does, so curl connects to the host Node checked.
  assert.deepEqual(envFor({ CLIP_OUTRO_URL: SMUGGLED }), {});
  for (const url of [
    ` ${HIT.CLIP_OUTRO_URL}`,
    `${HIT.CLIP_OUTRO_URL}\n`,
    "https://s3.exam\nple.com/outro_v1_1920x1080_60.mp4",
    "https://s3.example.com/outro_v1_1920x1080_60.mp4\t?s=1",
  ]) {
    assert.deepEqual(envFor({ CLIP_OUTRO_URL: url }), {}, JSON.stringify(url));
  }
});

test("drops a render without its logo or PUT URL", () => {
  const { CLIP_BRAND_LOGO_URL: _logo, ...noLogo } = MISS;
  const { CLIP_OUTRO_PUT_URL: _put, ...noPut } = MISS;
  assert.deepEqual(envFor(noLogo), {});
  assert.deepEqual(envFor(noPut), {});
  assert.deepEqual(envFor({ ...MISS, CLIP_BRAND_LOGO_URL: null }), {});
  assert.deepEqual(envFor({ CLIP_OUTRO_RENDER: "1" }), {});
  // Branding with neither a cached outro nor a render is no outro either.
  assert.deepEqual(envFor({ ...MISS, CLIP_OUTRO_RENDER: "0" }), {});
  assert.deepEqual(envFor({ CLIP_BRAND_NAME: "Adria" }), {});
});

test("drops every URL key when there is no allowed origin", () => {
  assert.deepEqual(envFor(HIT, null), {});
  assert.deepEqual(envFor(MISS, null), {});
});

test("drops keys outside the outro prefixes and null values", () => {
  const src = {
    ...HIT,
    PATH: "/tmp/evil",
    LD_PRELOAD: "/tmp/evil.so",
    CLIP_RENDER_TOKEN: "t",
    CLIP_BRAND_NAME: null,
    CLIP_BRAND_ACCENT: undefined,
  };
  assert.deepEqual(filterOutroEnv(src, ORIGIN), { env: HIT, dropped: null });
});

test("an absent or empty outro_env is no outro, not a dropped one", () => {
  for (const src of [undefined, null, "x", [], {}, { PATH: "/tmp/evil" }]) {
    assert.deepEqual(filterOutroEnv(src, ORIGIN), { env: {}, dropped: null });
  }
});

test("passes integer and decimal accents", () => {
  for (const accent of [
    "33 94% 58%",
    "224.3 76.3% 48%",
    "0 0% 0%",
    "360 100% 100%",
  ]) {
    const src = { ...MISS, CLIP_BRAND_ACCENT: accent };
    assert.deepEqual(envFor(src), src);
  }
});

test("drops the whole env for an accent that is not an HSL triple", () => {
  const bad = [
    "0 0% 0%) url(http://10.0.0.1/x",
    "red",
    "33 94% 58%;",
    "33 94% 58%\n",
    " 33 94% 58%",
    "",
  ];
  for (const accent of bad) {
    const why = JSON.stringify(accent);
    assert.deepEqual(envFor({ ...MISS, CLIP_BRAND_ACCENT: accent }), {}, why);
    assert.deepEqual(envFor({ ...HIT, CLIP_BRAND_ACCENT: accent }), {}, why);
  }
});

test("says why it dropped the env without logging a value", () => {
  const cases = [
    [{ ...MISS, CLIP_OUTRO_PUT_URL: ELSEWHERE }, /CLIP_OUTRO_PUT_URL/],
    [
      { ...MISS, CLIP_BRAND_ACCENT: "0 0% 0%) url(http://10.0.0.1/x" },
      /CLIP_BRAND_ACCENT/,
    ],
    [{ CLIP_OUTRO_RENDER: "1" }, /CLIP_OUTRO_RENDER=1/],
  ];
  for (const [src, reason] of cases) {
    const { dropped } = filterOutroEnv(src, ORIGIN);
    assert.match(dropped, reason);
    assert.ok(!dropped.includes("http"), dropped);
  }
});
