// Tracks the GSI `grenades` block so a nade preview capture can stop on the
// real detonation/bloom instead of a timer.
//
// GSI only ships `allgrenades` to an OBSERVER client (or a demo) — a client
// that joined as a player sees nothing here, so the recorder has to be able to
// tell "no grenade ever appeared" apart from "this server never sends grenade
// data at all". blocksSeen is that signal.

// GSI's own type names on the left of the arrow; the rest are the 5stack
// e_utility_types values (Smoke/Flash/HighExplosive/Molotov/Decoy, lowercased)
// so the api can arm the watch with the enum it already stores.
const TYPE_ALIASES = new Map([
  ["hegrenade", "frag"],
  ["he", "frag"],
  ["highexplosive", "frag"],
  ["flash", "flashbang"],
  ["smokegrenade", "smoke"],
  ["molotov", "firebomb"],
  ["incendiary", "firebomb"],
  ["incgrenade", "firebomb"],
]);

export const nadeWatch = {
  armedMs:      0,
  wantType:     null,
  thrownMs:     0,
  detonatedMs:  0,
  bloomMs:      0,
  type:         null,
  entityId:     null,
  active:       0,
  blocksSeen:   0,
  lastUpdateMs: 0,
  preIds:       new Set(),
  lastIds:      new Set(),
};

export function normalizeNadeType(raw) {
  if (typeof raw !== "string") return null;
  const t = raw.trim().toLowerCase();
  if (!t) return null;
  return TYPE_ALIASES.get(t) ?? t;
}

function seconds(raw) {
  const n = typeof raw === "number" ? raw : Number.parseFloat(raw);
  return Number.isFinite(n) ? n : 0;
}

export function armNadeWatch(wantType) {
  nadeWatch.armedMs     = Date.now();
  nadeWatch.wantType    = normalizeNadeType(wantType);
  nadeWatch.thrownMs    = 0;
  nadeWatch.detonatedMs = 0;
  nadeWatch.bloomMs     = 0;
  nadeWatch.type        = null;
  nadeWatch.entityId    = null;
  // Grenades already in the air when we armed (a previous lineup's smoke still
  // blooming) would otherwise be read as this lineup's throw.
  nadeWatch.preIds      = new Set(nadeWatch.lastIds);
}

export function disarmNadeWatch() {
  nadeWatch.armedMs  = 0;
  nadeWatch.wantType = null;
}

export function applyNadeUpdate(grenades) {
  const now = Date.now();
  nadeWatch.lastUpdateMs = now;

  const entries = grenades && typeof grenades === "object" ? Object.entries(grenades) : [];
  const ids = new Set();
  const fresh = [];
  for (const [id, g] of entries) {
    if (!g || typeof g !== "object") continue;
    ids.add(id);
    fresh.push({ id, type: normalizeNadeType(g.type), effect: seconds(g.effecttime) });
  }
  nadeWatch.lastIds = ids;
  nadeWatch.active = fresh.length;
  if (fresh.length > 0) nadeWatch.blocksSeen += 1;
  if (nadeWatch.armedMs === 0) return;

  const post = fresh.filter((g) => !nadeWatch.preIds.has(g.id));

  if (nadeWatch.entityId === null) {
    const want = nadeWatch.wantType;
    // A firebomb's own projectile can be missed between polls — its inferno is
    // proof enough that the throw happened.
    const match = post.find((g) =>
      !want || g.type === want ||
      (want === "firebomb" && g.type === "inferno"));
    if (match) {
      nadeWatch.entityId = match.id;
      nadeWatch.type     = match.type;
      nadeWatch.thrownMs = now;
    }
  }
  if (nadeWatch.entityId === null) return;

  const tracked = fresh.find((g) => g.id === nadeWatch.entityId);
  const bloom = post.reduce((max, g) => (g.effect > max ? g.effect : max), 0);
  if (bloom > 0) nadeWatch.bloomMs = Math.round(bloom * 1000);

  if (nadeWatch.detonatedMs === 0) {
    const inferno = post.some((g) => g.type === "inferno");
    // Smoke: the projectile keeps its slot and grows an effecttime. Everything
    // else (frag/flash/decoy) is simply gone the moment it goes off — but that
    // read is only safe once we've actually seen the entity in flight.
    const detonated =
      bloom > 0 ||
      inferno ||
      (tracked === undefined && nadeWatch.thrownMs > 0 && nadeWatch.type !== "smoke");
    if (detonated) nadeWatch.detonatedMs = now;
  }
}

export function nadeWatchLine() {
  const now = Date.now();
  const armed = nadeWatch.armedMs > 0;
  const ageMs = nadeWatch.lastUpdateMs > 0 ? now - nadeWatch.lastUpdateMs : -1;
  return [
    armed ? "1" : "0",
    String(ageMs),
    armed ? String(now - nadeWatch.armedMs) : "0",
    nadeWatch.thrownMs > 0 ? "1" : "0",
    nadeWatch.detonatedMs > 0 ? "1" : "0",
    String(nadeWatch.bloomMs),
    String(nadeWatch.active),
    nadeWatch.type ?? "",
    String(nadeWatch.blocksSeen),
  ].join("|");
}
