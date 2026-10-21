import process from "node:process";

// A switch leaves process.env on the match the pod booted for: the capture keeps
// that match's stream id, and the clip render inherits MATCH_ID to find it.
let switched = null;

const NON_BLANK = /\S/;
function isNonBlankString(v) {
  return typeof v === "string" && NON_BLANK.test(v);
}

function bootTarget() {
  return {
    matchId: process.env.MATCH_ID || null,
    matchPassword: process.env.MATCH_PASSWORD ?? process.env.CONNECT_TV_PASSWORD ?? null,
    connect: bootConnect(),
  };
}

function bootConnect() {
  if (isNonBlankString(process.env.PLAYCAST_URL)) {
    return { kind: "playcast", url: process.env.PLAYCAST_URL };
  }
  if (isNonBlankString(process.env.CONNECT_TV_ADDR)) {
    return {
      kind: "connect",
      addr: process.env.CONNECT_TV_ADDR,
      password: process.env.CONNECT_TV_PASSWORD ?? "",
    };
  }
  if (isNonBlankString(process.env.CONNECT_ADDR)) {
    return {
      kind: "connect",
      addr: process.env.CONNECT_ADDR,
      password: process.env.CONNECT_PASSWORD ?? "",
    };
  }
  return null;
}

export function podTarget() {
  return switched ?? bootTarget();
}

export function switchPodTarget({ matchId, matchPassword, connect }) {
  switched = { matchId, matchPassword, connect };
}
