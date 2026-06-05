import { demoLoadedInProc, demoState, estimateCurrentTick } from "../state/demo.mjs";
import { gsiState } from "../state/gsi.mjs";
import { playingState } from "../reporters/demo-playing.mjs";
import { sendJson } from "../util/http.mjs";

export async function demoStateHandler(_req, res) {
  const gsiFresh =
    gsiState.lastReceivedMs > 0 &&
    Date.now() - gsiState.lastReceivedMs < 30_000;
  const demoLoaded =
    gsiFresh && gsiState.mapPhase != null ? true : await demoLoadedInProc();
  // Sum of every player's position — a real "is the demo advancing"
  // signal. The `tick` above is a wall-clock estimate that advances the
  // moment we mark playback resumed, so it can't detect a frozen cs2;
  // player movement can. Static across polls = demo actually frozen.
  let worldMotion = 0;
  for (const p of gsiState.players.values()) {
    if (p.position) worldMotion += p.position[0] + p.position[1] + p.position[2];
  }
  worldMotion = Math.round(worldMotion);
  sendJson(res, 200, {
    tick: estimateCurrentTick(),
    total_ticks: demoState.totalTicks,
    tick_rate: demoState.tickRate,
    rate: demoState.rate,
    paused: demoState.paused,
    last_activity_ms_ago: Date.now() - demoState.lastActivityMs,
    demo_loaded: demoLoaded,
    gsi: gsiFresh
      ? {
          map_name: gsiState.mapName,
          map_phase: gsiState.mapPhase,
          round_phase: gsiState.roundPhase,
          phase_ends_in: gsiState.phaseEndsIn,
          round_number: gsiState.roundNumber,
          spectated_steam_id: gsiState.spectatedSteamId,
          last_received_ms_ago: Date.now() - gsiState.lastReceivedMs,
          spec_slots: gsiState.specSlots,
          world_motion: worldMotion,
          team_ct_name: gsiState.teamCtName,
          team_t_name:  gsiState.teamTName,
          team_ct_score: gsiState.teamCtScore,
          team_t_score:  gsiState.teamTScore,
          demoui_hidden: playingState.demouiHidden,
        }
      : null,
  });
}
