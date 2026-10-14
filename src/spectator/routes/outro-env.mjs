// Outro/branding env for render-clip.mjs, from its UNTRUSTED POST body (the
// endpoint is unauthenticated and the pod is host-networked). The api sends
// one of two shapes, which outro.sh reads:
//   hit:  CLIP_OUTRO_URL
//   miss: CLIP_OUTRO_RENDER=1, CLIP_OUTRO_PUT_URL, CLIP_BRAND_LOGO_URL,
//         CLIP_BRAND_NAME (may be empty), CLIP_BRAND_ACCENT
// Only CLIP_OUTRO_*/CLIP_BRAND_* keys may reach the render env, and they pass
// whole or not at all: one rejected key, or an env that forms neither shape,
// drops every key, so the clip gets the baked stock outro. Dropping just the
// bad key would leave a render without its logo or PUT URL, and outro.sh would
// render the stock logo next to the community's name and accent (a
// half-branded outro) and never fill the shared cache. A key is rejected when
// it is:
//  - a URL key whose origin is not the S3_PUBLIC_ORIGIN the pod gets (or
//    DEMO_URL's origin), or that is not the URL as Node serializes it (see
//    hasOrigin). Otherwise the logo <Img src> (headless Chromium) or the curl
//    GET/PUT of the cached outro could be pointed at an internal URL (SSRF)
//    or any host (arbitrary write).
//  - a CLIP_BRAND_ACCENT that is not an HSL triple. The Outro puts it in its
//    CSS as is, so "0 0% 0%) url(http://...)" would make Chromium fetch a URL
//    of the caller's choice.
const URL_KEYS = [
  "CLIP_OUTRO_URL",
  "CLIP_OUTRO_PUT_URL",
  "CLIP_BRAND_LOGO_URL",
];

// An HSL triple as the web saves a theme colour: whole numbers from its colour
// picker ("33 94% 58%") or the decimals of its stock palette ("224.3 76.3% 48%").
// The api and motion/src/Outro.tsx check the accent against the same pattern.
export const OUTRO_ACCENT_RE =
  /^\d{1,3}(\.\d+)? \d{1,3}(\.\d+)?% \d{1,3}(\.\d+)?%$/;

// { env, dropped }: the outro env to render with, and why a non-empty one was
// dropped (null when it was not). The reason names a key, never a value: the
// URLs are presigned.
export function filterOutroEnv(src, allowedOrigin) {
  const env = {};
  for (const [k, v] of Object.entries(
    src && typeof src === "object" ? src : {},
  )) {
    if (
      (k.startsWith("CLIP_OUTRO_") || k.startsWith("CLIP_BRAND_")) &&
      v != null
    ) {
      env[k] = String(v);
    }
  }
  const dropped =
    Object.keys(env).length > 0 ? rejectReason(env, allowedOrigin) : null;
  return dropped ? { env: {}, dropped } : { env, dropped: null };
}

function rejectReason(env, allowedOrigin) {
  for (const k of URL_KEYS) {
    if (env[k] !== undefined && !hasOrigin(env[k], allowedOrigin)) {
      return `${k} is not a URL at the S3 origin`;
    }
  }
  const accent = env.CLIP_BRAND_ACCENT;
  if (accent !== undefined && !OUTRO_ACCENT_RE.test(accent)) {
    return "CLIP_BRAND_ACCENT is not an HSL triple";
  }
  const hit = env.CLIP_OUTRO_URL !== undefined;
  const render =
    env.CLIP_OUTRO_RENDER === "1" &&
    env.CLIP_OUTRO_PUT_URL !== undefined &&
    env.CLIP_BRAND_LOGO_URL !== undefined;
  if (!hit && !render) {
    return "neither CLIP_OUTRO_URL nor CLIP_OUTRO_RENDER=1 with PUT and logo URLs";
  }
  return null;
}

// The string must also be the URL as Node serializes it (href): outro.sh hands
// the hit and PUT URLs to curl, whose parser reads a backslash in the
// authority differently. For "https://s3.example.com\@10.0.0.1:9000/x" Node
// gives the origin https://s3.example.com (and the path /@10.0.0.1:9000/x),
// so the origin check alone passes, while curl takes "s3.example.com\" as
// userinfo and connects to 10.0.0.1:9000. Node serializes that string
// differently from how it came in, as it does one with tabs, newlines or
// outer spaces (which it strips), so curl only gets a URL whose host both
// parsers read alike. A presigned URL serializes to itself.
function hasOrigin(value, allowedOrigin) {
  try {
    const u = new URL(value);
    return !!allowedOrigin && u.origin === allowedOrigin && u.href === value;
  } catch {
    return false;
  }
}
