import fs from "fs/promises";
import { exec } from "child_process";
import { OBSWebSocket } from "obs-websocket-js";
import { parseEvent, parseTicks } from "@laihoe/demoparser2";

// obs --startvirtualcam --minimize-to-tray --profile "Default" --collection "HUDCollection"

// set DefensiveConCommands to 0 in game/csgo_core/gameinfo.gi

async function execCommand(command) {
  return new Promise((resolve, reject) => {
    console.info(`executing command: ${command}`);
    exec(command, (error) => {
      if (error) {
        // TODO - figure out what todo , probably restart
        reject(error);
      }
      resolve();
    });
  });
}

// await execCommand('apt update');
// await execCommand('apt install obs-studio -y');

// // Wait until CS2 window is found
// let startTime = Date.now();
// while (Date.now() - startTime < 30000) {
//     try {
//         await execCommand('wmctrl -a "Obs"');
//         break;
//     } catch (e) {
//         console.info('waiting for OBS');
//         await new Promise(resolve => setTimeout(resolve, 1000));
//     }
// }

// CHECK IF THERE IS A APP MANIFEST , if not create it
// await fs.writeFile(`/mnt/games/GameLibrary/Steam/steamapps/appmanifest_730.acf`, '"AppState" { "appid" "730" "Universe" "1" "StateFlags" "1026" "installdir" "Counter-Strike Global Offensive" "LastUpdated" "0" "UpdateResult" "0" "SizeOnDisk" "0" "buildid" "0" }');

// CHECK IF CS IS DOWNLOADING
// /mnt/games/GameLibrary/Steam/steamapps/downloading

// Get server address from command line args (format: ip:port or just ip)
const serverAddr = process.argv[3]; // e.g., "10.0.2.222:27015" or "10.0.2.222"

// connect [A:1:2957550595:48359]; password game:administrator:bTeah-qhSqxRmDRaHQUkkNWHajhpwhQQtuYlJEH7dsk=
// LAUNCH CS2
let launchCommand;
if (serverAddr) {
  launchCommand = `steam "steam://connect/76.139.106.28:30026";`;
  console.info(
    `Launching CS2 and connecting to spectator server: ${serverAddr}`,
  );
} else {
  launchCommand = "steam steam://rungameid/730";
  console.info("Launching CS2 (no server specified)");
}
await execCommand(launchCommand);

// Wait until CS2 window is found
startTime = Date.now();
while (Date.now() - startTime < 30000) {
  try {
    await execCommand('wmctrl -a "Counter-Strike 2"');
    break;
  } catch (e) {
    console.info("waiting for CS2 window");
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
}

// // await execCommand('obs --profile "AutoStreamProfile" --collection "OpenHud" --startstreaming');

// //TODO - wait till were able to start dmeo
// await new Promise(resolve => setTimeout(resolve, 15 * 1000));

// async function getTickRanges(demoPath, player) {
//     let kills = parseEvent(demoPath, "player_death", ["last_place_name", "team_name"], ["total_rounds_played", "is_warmup_period"])

//     let killsNoWarmup = kills.filter(kill => kill.is_warmup_period == false)
//     let filteredKills = killsNoWarmup.filter(kill => kill.attacker_team_name != kill.user_team_name)
//     let maxRound = Math.max(...kills.map(o => o.total_rounds_played))

//     const killsPerRound = {};
//     for (let round = 0; round <= maxRound; round++){
//         let killsThisRound = filteredKills.filter(kill => kill.total_rounds_played == round)
//         for (const item of killsThisRound) {
//             if(item.attacker_name !== player) {
//                 continue;
//             }

//             if(!killsPerRound[round]) {
//                 killsPerRound[round] = [];
//             }

//             killsPerRound[round].push({
//                 player: item.attacker_name,
//                 tick: item.tick,
//             });
//         }
//     }

//     return killsPerRound;
// }

// async function startDemo() {
//     console.info('starting demo');
//     const commands = [
//         'wmctrl -a "Counter-Strike 2"',
//         'xdotool key "grave"',
//         'xdotool key "ctrl+a"',
//         'xdotool key "Delete"',
//         'xdotool type "playdemo test"',
//         'xdotool key Return',
//         'xdotool key "grave"'
//     ];

//     for (let i = 0; i < commands.length; i++) {
//         await new Promise(resolve => setTimeout(resolve, 100));
//         await execCommand(commands[i]);
//     }
// }

// async function clipDemo(demoPath, tick, player) {
//     let players = parseTicks(demoPath, ["user_id", "team_name"], [tick])
//     let ctPlayers = players.filter(x => x.team_name == "CT")
//     let tPlayers = players.filter(x => x.team_name == "TERRORIST")

//     ctPlayers.sort((a,b) => a.user_id - b.user_id)
//     tPlayers.sort((a,b) => a.user_id - b.user_id)

//     let slots = []
//     slots.push(...ctPlayers)
//     slots.push(...tPlayers)

//     for (let i = 1; i < slots.length; i++){
//         slots[i]["slot_num"] = i
//     }

//     const slot = slots.find((slot) => {
//         return slot.name === player;
//     });

//     if(!slot) {
//         console.info(`player ${player} not found`);
//         return;
//     }

//     // a tick is 64 frames, lets jump back 5 seconds
//     const tickToJumpTo = tick - (5 * 64);

//     const commands = [
//         'wmctrl -a "Counter-Strike 2"',
//         'xdotool key "grave"',
//         'xdotool key "ctrl+a"',
//         'xdotool key "Delete"',
//         `xdotool type "demo_gototick ${tickToJumpTo}"`,
//         'xdotool key Return',
//         `xdotool type "spec_player ${slot.user_id + 1}"`,
//         'xdotool key Return',
//         'xdotool key "grave"'
//     ];

//     for (let i = 0; i < commands.length; i++) {
//         await new Promise(resolve => setTimeout(resolve, 100));
//         await execCommand(commands[i]);
//     }

//     await obs.call('SetOutputSettings', {
//         outputName: "simple_file_output",
//         outputSettings: {
//             record_folder: "/home/default/Videos",
//             record_filename: `${player}-${tick}.mp4`
//         },
//      });

//     console.info("START RECORD");
//     await obs.call('StartRecord');

//     await new Promise(resolve => setTimeout(resolve, 10 * 1000));

//     console.info("STOP RECORD");
//     await obs.call('StopRecord');
// }

// // await startDemo();

// async function watchLive() {
//     console.info('starting demo');
//     const commands = [
//         'wmctrl -a "Counter-Strike 2"',
//         'xdotool key "grave"',
//         'xdotool key "ctrl+a"',
//         'xdotool key "Delete"',
//         'xdotool type "playdemo test"',
//         'xdotool key Return',
//         'xdotool key "grave"'
//     ];

//     for (let i = 0; i < commands.length; i++) {
//         await new Promise(resolve => setTimeout(resolve, 100));
//         await execCommand(commands[i]);
//     }
// }

// await watchLive()

// // TODO - not sure how long it takes to boot the demo
// // wait for 10 seconds
// // await new Promise(resolve => setTimeout(resolve, 10 * 1000));

// // const player = process.argv[2];
// // const demoPath = "/home/default/.steam/steam/steamapps/common/Counter-Strike Global Offensive/game/csgo/test.dem";

// // for(const [round, ticks] of Object.entries(await getTickRanges(demoPath, player))) {
// //     console.info(`round ${round}`, ticks);
// //     for(const { tick } of ticks) {
// //         try {
// //             await clipDemo(demoPath, tick, player);
// //         } catch (err) {
// //             console.error(`Failed to clip demo at tick ${tick}:`, err.message);
// //             throw err;
// //         }
// //     }
// // }

// console.info("done.")
