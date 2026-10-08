// How the render pod acts a lineup's throw out with its own keys. The flight
// is not decided here: the practice plugin snaps the projectile to the recorded
// seed the moment it exists. This only makes the throw LOOK like the lineup --
// right click for a lob, a jump for a jump throw -- so the viewmodel and the
// player's body do what the write-up says.
//
// Returns three console command strings, each run through exec-cfg:
//   press   -- held while the pin is pulled
//   release -- the instant the grenade leaves the hand
//   after   -- puts every key back up once the throw is away

const JUMP_TECHNIQUES = new Set(["jump", "runjump", "walkjump", "crouchjump"]);
const CROUCH_TECHNIQUES = new Set(["crouch", "crouchjump"]);

export function nadeActKeys({ technique, strength, jumpBind } = {}) {
  const tech = String(technique ?? "").trim().toLowerCase();
  const grip = String(strength ?? "").trim().toLowerCase();

  let hold;
  switch (grip) {
    case "half":
      hold = ["attack", "attack2"];
      break;
    case "drop":
      hold = ["attack2"];
      break;
    default:
      hold = ["attack"];
  }

  const crouch = CROUCH_TECHNIQUES.has(tech);
  const jump = jumpBind === true || JUMP_TECHNIQUES.has(tech);

  const press = [...(crouch ? ["+duck"] : []), ...hold.map((key) => `+${key}`)];
  const release = [...(jump ? ["+jump"] : []), ...hold.map((key) => `-${key}`)];
  const after = [...(jump ? ["-jump"] : []), ...(crouch ? ["-duck"] : [])];

  return {
    press: press.join("; "),
    release: release.join("; "),
    after: after.join("; "),
  };
}
