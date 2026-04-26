# 5stack game-streamer

GPU-backed CS2 container that brings up Steam, joins a SourceTV/playcast
broadcast, and publishes an NVENC-encoded H.264 + AAC stream to MediaMTX
over SRT. Headless — Xorg-dummy + openbox, no VNC/Selkies/SSH.

CS2 is installed at pod start via `steamcmd` into a host-mounted cache so
subsequent pods skip the ~57 GB download.

## Layout

```
Dockerfile                  # nvidia/cuda base + Xorg + GStreamer + steamcmd + 32-bit Steam UI deps
xorg-dummy.conf             # dummy-driver X config (NVIDIA GLX/Vulkan at runtime)
src/
  game-streamer.sh          # entry / subcommand dispatcher
  flows/
    setup-steam.sh          # flow 1: bring Steam up (login, library, cloud disable, cycle)
    run-live.sh             # flow 2: -applaunch CS2 + start match capture stream
  lib/
    common.sh               # log/run/dump_log helpers, env defaults
    xorg.sh                 # Xorg/openbox/xhost, x-window helpers, dialog poke
    audio.sh                # PulseAudio + cs2 null sink, default-source resolution
    stream.sh               # gstreamer SRT capture (video + audio leg)
    steam.sh                # Steam bootstrap, library reg, steamcmd CS2 install,
                            # cloud disable (registry/config/local/sharedconfig),
                            # perms fix, full-debug dump
  .env.example              # copy to src/.env (gitignored) and fill in
```

## Running

```bash
src/game-streamer.sh live          # end-to-end: setup-steam then run-live
src/game-streamer.sh --debug live  # also publish a debug capture to publish:debug

src/game-streamer.sh setup-steam   # just flow 1
src/game-streamer.sh run-live      # just flow 2 (Steam must already be logged in)
```

`live` runs both flows in sequence. setup-steam blocks until the main
Steam UI window is rendered (= login fully complete + userdata on disk)
before run-live issues the `-applaunch`.

## Required env (`src/.env`)

```bash
# Steam login (account must NOT have Steam Guard / 2FA)
STEAM_USERNAME=...
STEAM_PASSWORD=...

# Match — pick one of:
MATCH_ID=...
PLAYCAST_URL=...                   # HTTP-broadcast mode
# or
CONNECT_ADDR=<ip>:<port>           # SourceTV port
CONNECT_PASSWORD=tv:streamer:<token>
```

Optional: `DEBUG_CAPTURE=1` (or pass `--debug`), `FPS=60`, `VIDEO_KBPS=6000`,
`STEAM_LIBRARY=/mnt/game-streamer`, `MEDIAMTX_SRT_BASE=srt://mediamtx.5stack.svc.cluster.local:8890`.

## Subcommands

| Command | Purpose |
|---|---|
| `live` | end-to-end (setup-steam + run-live) |
| `setup-steam` | flow 1 only |
| `run-live` | flow 2 only |
| `status` / `state` | xorg / steam / streams / cs2 / x windows |
| `windows` | print currently-mapped X windows |
| `dismiss` | activate Steam window + send Space (dismisses CEF dialogs) |
| `hide-steam` | minimize the Steam main UI + Friends List |
| `cs2-console` | open CS2 dev console (sends backtick to cs2 window) |
| `cs2-connect` | open console + type `connect <addr>; password "<pw>"` |
| `audio-state` | print PulseAudio sinks/sources/sink-inputs |
| `audio-test` | play a 2s 440Hz tone into the cs2 sink (smoke-test the capture) |
| `install-cs2` | run steamcmd CS2 install/update (kills Steam first) |
| `cloud-state` | print Cloud disable state from disk |
| `cloud-debug` | verbose dump of every cloud-related VDF block |
| `disable-cloud` | cycle Steam: kill -9 → edit cloud=off → relaunch |
| `steam-log` | tail Steam's logs (steam.log, console-linux, cef, webhelper) |
| `gst-log [stream-id]` | tail a capture's gstreamer log |
| `debug` | full diagnostic dump (env, processes, pipe, runtime, logs, cloud, disk) |
| `stop-live` / `stop-all` | kill cs2+capture / everything |

`--trace` / `-x` enables `set -x` across the entry script.

## How it actually works

**setup-steam (one-time per pod):**

1. Xorg + openbox + xhost
2. PulseAudio + a `cs2` null sink (gst captures from `cs2.monitor`)
3. (`--debug` only) start the screen-capture stream to `publish:debug`
4. Symlink `$STEAM_HOME` → `$STEAM_LIBRARY/steam` (single mount; avoids
   the EXDEV bug from a separate bind mount)
5. `chown -RH root:root` + `chmod -RH u+rwX` on Steam home, nuke stale
   `package/` cache (host volumes accumulate `1000:1000` ownership from
   prior pods)
6. Register `$STEAM_LIBRARY` in `libraryfolders.vdf`
7. `steamcmd +app_update 730 validate` — idempotent fast-path when the
   manifest already shows installed
8. Disable Steam Cloud at every known location: `registry.vdf` global
   `CloudEnabled`, `config/config.vdf` `Cloud { EnableCloud }`, per-user
   `localconfig.vdf` `apps/730/cloudenabled`, per-user `7/remote/sharedconfig.vdf`
   (synthesizes the apps/730 block if missing)
9. Launch Steam, wait for IPC pipe + main UI window
10. First-boot only (no userdata existed before this run): SIGKILL Steam
    (no graceful shutdown = no clobber of our cloud edits), re-apply the
    cloud disable now that userdata exists, relaunch, wait for window again

**run-live:**

1. Preflight (Steam pipe up, Xorg up, restore real `steamclient.so`)
2. Cleanup any stale cs2/capture for this MATCH_ID
3. Write `autoexec.cfg` + `live_autoexec.cfg` with the connect/playcast line
4. `PULSE_SINK=cs2` exported, `-applaunch 730` issued with launch args
5. Wait for cs2 process — every 5s for the first 90s, send Space to the
   Steam window to dismiss any CEF dialog (cloud-out-of-date "Play anyway"
   / shader pre-cache "Skip" — both have the default action focused). At
   30s without spawn, re-issue applaunch once (Steam ignores the very
   first applaunch on a fresh login sometimes)
6. Once cs2 spawns, hide the Steam main UI + Friends List
7. Wait for the cs2 window
8. Start the gst capture: `ximagesrc → nvh264enc → mpegtsmux ←
   pulsesrc(default-source) → avenc_aac` → SRT publish

## Connect via launch args (status: not auto-firing)

CS2 doesn't currently honor `+exec live_autoexec` / `+connect` / `+password`
launch args reliably from `-applaunch 730` on Linux — observed by zero
`Executing autoexec.cfg` lines in cs2's log post-launch. The autoexec is
written, but cs2 lands at the main menu and you have to issue:

```bash
src/game-streamer.sh cs2-connect
```

…which sends the connect string via the dev console. We auto-fire this
in run-live before the match capture starts.

## Build

```bash
docker build -t ghcr.io/5stackgg/game-streamer:dev .
```

## Deployment

Single cache mount at `/mnt/game-streamer`. The Steam-home symlink
inside that mount is what makes the persisted layout work without
EXDEV during Steam self-update:

```yaml
volumeMounts:
  - { name: dshm,  mountPath: /dev/shm }
  - { name: cache, mountPath: /mnt/game-streamer }
```

Per-match streamer pods are spawned by the 5stack API (`api/src/matches/game-streamer/game-streamer.service.ts`).
The dev pod manifest lives at `5stack-panel/overlays/dev/dev-game-streamer/deployment.yaml`.

## Known issues / landmines

- **Steam account must not have Steam Guard / 2FA enabled.** No
  interactive console to enter codes. The runtime `STEAM_USERNAME` is
  expected to be a dedicated service account.
- **CS2 self-update on a stale Steam install can fail with EXDEV** if
  `$STEAM_HOME` ends up as a separate bind mount from the underlying
  host path. The single-cache-mount + symlink pattern in this repo
  avoids that. If you change deployment topology, re-test.
- **Steam refuses to run as root** unless `--system` mode. We start it
  in user mode anyway — the warning is benign, but `pulseaudio --start`
  needs `XDG_RUNTIME_DIR` set (`common.sh` does this).
- **i386 deps for `steamui.so` dlmopen.** `libglib2.0-0:i386` and
  friends are required at the system level (Steam's bundled runtime
  isn't visible to dlmopen's fresh linker namespace). Already in the
  Dockerfile.
- **NVIDIA driver 570.x/580.x NVENC multi-GPU regression**
  ([nvidia-container-toolkit#1249](https://github.com/NVIDIA/nvidia-container-toolkit/issues/1249))
  — pin to single-GPU nodes until resolved.

## Diagnosing

When something goes wrong, the first thing to do is:

```bash
src/game-streamer.sh debug > /tmp/debug.txt 2>&1
```

That dumps the full picture in one file. The window-wait timeout in
`setup-steam` also auto-fires the same dump.

For a specific subsystem:

| Symptom | Command |
|---|---|
| Steam doesn't render UI / pipe up but no webhelper | `steam-log` (look for `dlmopen ... wrong ELF class` or `BCommitUpdatedFiles ... error 18`) |
| "Cloud Out of Date" dialog | `cloud-state` to see what's set; `cloud-debug` for raw VDF; `disable-cloud` to re-cycle |
| Audio missing on stream | `audio-state` to verify cs2 routes to the cs2 sink; `audio-test` to send a tone |
| Capture stream dies | `gst-log <match-id>` (most common: `pulsesrc ... No such entity` = sink missing) |
| Cs2 doesn't spawn | match capture wait loop dumps every 15s; check `cs2_launch.log` |
