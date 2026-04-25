# 5stack game-streamer

GPU container that runs the **real Steam client** (logged into a CS2-licensed
account) and uses CS2 for two jobs:

1. **`MODE=live`** — CS2 joins a match's GOTV / `playcast`, Xorg-dummy
   renders to a virtual display, GStreamer NVENC-encodes the framebuffer
   + PulseAudio capture, and pushes SRT to in-cluster MediaMTX. Viewers
   watch over HLS at `https://hls.5stack.gg/<MATCH_ID>/`.

2. **`MODE=create-clips`** *(draft)* — CS2 `+playdemo`s a `.dem`, seeks to
   a tick, specs a player, and records a per-clip mp4. Upstream demo
   ingestion + downstream upload (TypeScript) are not built yet.

## Layout

```
Dockerfile               # nvidia/cuda base + Xorg-dummy + Steam + GStreamer
codepier.yaml            # dev sync target
resources/
  xorg-dummy.conf        # baked into /etc/X11/ at image build
  live_autoexec.cfg      # appended to live mode's generated autoexec
src/
  game-streamer.sh       # ENTRYPOINT — boots stack + dispatches on $MODE
                         # Also doubles as operator CLI (see below).
  actions/               # one script per MODE
    live.sh              # MODE=live
    create-clips.sh      # MODE=create-clips  (draft)
  lib/                   # sourced by game-streamer.sh
    common.sh            # log(), env defaults
    xorg.sh              # start_xorg, start_openbox
    audio.sh             # start_pulseaudio (auto-on by default)
    steam.sh             # persist + register library + run Steam,
                         # install_or_update_cs2 (called every boot)
    cs2.sh               # write_autoexec, launch_cs2_via_steam, quit_cs2
    gst.sh               # capture_to_srt, record_to_mp4
  dev/                   # diagnostic-only scripts dispatched via the
                         # operator CLI (see the table below)
```

## Boot sequence

Every action depends on the same runtime: a logged-in Steam, an
up-to-date CS2 install, Xorg + audio. `game-streamer.sh::prepare_runtime`
runs that common setup before anything action-specific:

1. **`ensure_user_namespaces`** — fail loud if the pod isn't `privileged: true`.
2. **`persist_steam_state`** — symlink `~/.local/share/Steam` →
   `/mnt/game-streamer/steam` so Steam login + downloads survive restarts.
3. **`ensure_steam_library`** — register `/mnt/game-streamer` as a Steam
   library; migrate any legacy install into the proper Steam layout.
4. **`start_xorg`** — Xorg-dummy + openbox + `xhost +local:`.
5. **`start_pulseaudio`** — in-pod user daemon, null sink `cs2` used as
   the GStreamer audio source.
6. **`start_steam`** — install the Steam bootstrap on first boot, then
   `steam.sh -silent -login` and wait for IPC.
7. **`ensure_steamclient`** — symlink `steamclient.so` to wherever Steam
   extracted it.
8. **`install_or_update_cs2`** — authenticated `steamcmd +app_update 730
   validate`. Always pulls the latest public build before any action runs.

Then `exec` the action — `actions/live.sh` or `actions/create-clips.sh` —
based on `$MODE`. Subcommands (operator CLI) skip `prepare_runtime` and
act on whatever state is already there.

## Operator CLI

Same script, with a subcommand argument, runs targeted actions instead of
booting:

```bash
kubectl -n 5stack exec -it deploy/game-streamer-live -- \
  /opt/game-streamer/src/game-streamer.sh <cmd>
```

| cmd | maps to | what |
|---|---|---|
| `state`           | `dev/state.sh`              | Processes, X windows, Steam pipe, dump dirs, recent logs. `state reset` kills CS2/GStreamer/Steam + clears temp state. `state dismiss` clicks Return on any blocking dialog. `state libs` shows pango/gtk/freetype versions. |
| `debug-steam`     | `dev/debug-steam-launch.sh` | "Steam IPC accepts -applaunch but never spawns CS2" diagnostic. Walks pipe state, library folders, manifest, symlink, account info, then tries `steam://install/730` + `steam://run/730`. |
| `debug-cs2-crash` | `dev/debug-cs2-crash.sh`    | Launches CS2 directly (no GStreamer wrapper), captures core dump, prints gdb backtrace. |
| `console-connect` | `dev/console-connect.sh`    | Types a `connect` / `playcast` / `connect_tv` command into CS2's console via xdotool. Use when the autoexec didn't fire. Reads `CONNECT_ADDR`, `CONNECT_PASSWORD`, `PLAYCAST_URL`, or `CONNECT_TV_ADDR` from env. |
| `quit-cs2 [hard]` | `lib/cs2.sh::quit_cs2`      | Stop CS2 + GStreamer publish stream. Steam/Xorg/openbox untouched. `hard` also clears stale lock files. |
| `update-cs2`      | `lib/steam.sh::install_or_update_cs2` | Re-run authenticated `steamcmd +app_update 730 validate`. (Already runs on every boot.) |
| `help`            | —                           | self-prints |

### Common workflows

```bash
# Full state dump
game-streamer.sh state

# Force-update CS2 to latest:
game-streamer.sh quit-cs2 && game-streamer.sh update-cs2

# Investigate a CS2 segfault (writes core to /tmp/core.cs2.<pid>):
game-streamer.sh debug-cs2-crash

# Drive CS2 console because the autoexec didn't fire:
export CONNECT_ADDR=host:port
export CONNECT_PASSWORD='tv:user:…'
game-streamer.sh console-connect
```

## MODE=live env

Required: `MATCH_ID` plus one of:
- `CONNECT_ADDR` (+ optional `CONNECT_PASSWORD`) — direct join + spectate
- `CONNECT_TV_ADDR` (+ optional `CONNECT_TV_PASSWORD`) — GOTV
- `PLAYCAST_URL` — Valve broadcast URL

Output: `srt://.../?streamid=publish:$MATCH_ID` →
`https://hls.5stack.gg/$MATCH_ID/`.

## MODE=create-clips env *(draft)*

Required: `DEMO_PATH`, `CLIP_NAME`, `START_TICK`, `END_TICK`, `SPEC_SLOT`.
Optional: `CLIP_LEAD_SECONDS` (default 5), `CLIP_TAIL_SECONDS` (default 3),
`CLIPS_DIR` (default `/mnt/game-streamer/clips`).

Upload of the produced mp4 is intentionally not wired here — a separate
TypeScript service will consume `$CLIPS_DIR`.

## Build

```bash
docker build -t ghcr.io/5stackgg/game-streamer:dev .
```

CI builds `:latest` on push to `main` via `.github/workflows/build.yaml`.

## Deploy

Manifests in `5stack-panel/overlays/game-streamer/`:

- `live-job.yaml` — Deployment, replicas:1, MODE=idle by default.
  Operator patches `MODE=live` + `MATCH_ID` + `CONNECT_*`/`PLAYCAST_URL`
  to actually broadcast.
- `highlight-worker-deployment.yaml` — replicas:0, MODE=create-clips,
  scaled by the (future) highlight pipeline.
- `game-streamer-config.env` — non-secret env (display, encoder,
  MediaMTX URLs).

Steam credentials come from the cluster-shared `steam-secrets` Secret
(`overlays/local-secrets/steam-secrets.env` — `STEAM_USER` +
`STEAM_PASSWORD`), `envFrom`'d directly. No game-streamer-specific Secret.

Both manifests need `securityContext.privileged: true` (Steam's bwrap
sandbox needs user namespaces). The Steam account must have **Steam Guard
disabled** so unattended `-silent -login` succeeds.

```bash
./5stack-panel/game-streamer.sh
```

deploys the kustomization.

## Storage

`/mnt/game-streamer` is a `hostPath` mount of `/opt/5stack/game-streamer`
on the GPU node:

```
/mnt/game-streamer/
├── steam/                # symlinked from ~/.local/share/Steam
├── steamapps/
│   ├── appmanifest_730.acf
│   └── common/Counter-Strike Global Offensive/   # the CS2 install
├── libraryfolder.vdf     # marker so Steam treats this as a library
├── demos/                # incoming .dem files for create-clips
└── clips/                # rendered mp4 outputs
```

## Known issues

- NVIDIA driver 570.x/580.x NVENC multi-GPU regression
  ([nvidia-container-toolkit#1249](https://github.com/NVIDIA/nvidia-container-toolkit/issues/1249))
  — pin to single-GPU nodes until resolved.
- CS2 client/server build mismatch surfaces as "Server is out of date".
  `install_or_update_cs2` always pulls the latest public build — if a
  server is behind, fix it on the game-server side.
- First boot on an empty persistent volume requires the Steam Guard email
  flow if Steam Guard is on. Account must have it OFF.
