# 5stack game-streamer

GPU-backed CS2 container for two jobs:

1. **Live stream** a match via GOTV spectator — `MODE=live`.
2. **Render highlight clips** from a `.dem` file — `MODE=render`.

No Selkies, no VNC, no SSH. Xorg-dummy + NVENC + GStreamer publishing to
MediaMTX (self-hosted, see `5stack-panel/overlays/mediamtx/`). CS2 is
installed at pod-start via `steamcmd` (appid 730, anonymous login) into a
shared `/cache` PVC so subsequent pods skip the download.

## Layout

```
Dockerfile              # nvidia/cuda base + Xorg-dummy + GStreamer + steamcmd
xorg-dummy.conf         # dummy-driver X config (NVIDIA GLX/Vulkan at runtime)
cfg/                    # CS2 autoexec cfgs copied into the install
scripts/
  entrypoint.sh         # starts Xorg, installs CS2, dispatches on MODE
  live.sh               # MODE=live — CS2 GOTV + GStreamer -> SRT/WHIP
  render.sh             # MODE=render — playdemo + per-clip record -> S3
  s3-upload.py          # minimal V4 PUT, no boto3 dep
highlights/             # Go tool using demoinfocs-golang to find clip moments
```

## Modes

`MODE=live` (required env: `MATCH_ID`, `CONNECT_TV_ADDR`, one of
`MEDIAMTX_SRT_URL` / `MEDIAMTX_WHIP_URL`) launches a CS2 GOTV spectator and
pushes NVENC-encoded H.264 to MediaMTX. Viewers watch via HLS / WHEP through
the MediaMTX ingress.

`MODE=render` (required env: `DEMO_PATH`, `CLIP_NAME`, `START_TICK`,
`END_TICK`, `SPEC_SLOT`) launches CS2 with `+playdemo`, seeks to
`START_TICK - CLIP_LEAD_SECONDS*64`, specs the given player, records the
framebuffer via NVENC, and (if `S3_*` env is set) uploads the mp4.

`MODE=install` pre-warms `/cache/cs2` via steamcmd and exits — useful as a
one-shot InitContainer / Job on a fresh PVC.

## Highlight pipeline

1. Match ends → 5stack uploads the `.dem` to `S3_BUCKET_DEMOS`.
2. A match-ended job runs `highlights -match <id> -demo <path>` and pipes
   each JSON line to NATS subject `highlights.render`.
3. The `highlight-worker` Deployment consumes those messages, sets the env
   vars, and runs the same image in `MODE=render`.

## Build

```bash
docker build -t ghcr.io/5stackgg/game-streamer:dev .
```

Smoke test locally (requires `nvidia-container-toolkit`):

```bash
docker run --rm --gpus all \
  -e MODE=install \
  -v $PWD/cache:/cache \
  ghcr.io/5stackgg/game-streamer:dev
```

## Known issues / landmines

- NVIDIA driver 570.x/580.x NVENC multi-GPU regression
  ([nvidia-container-toolkit#1249](https://github.com/NVIDIA/nvidia-container-toolkit/issues/1249))
  — pin to single-GPU nodes until resolved.
- `startmovie` on Linux-native CS2 is less battle-tested than on Windows.
  The current render pipeline captures the live framebuffer (GStreamer
  `ximagesrc`) instead — more reliable, slightly less deterministic.
- The `/cache` PVC must be `ReadWriteMany` so multiple render workers can
  share the CS2 install + demo cache.



export MATCH_ID=8d3b87c5-cf7a-49b8-b49e-faca8ca0113a
export CONNECT_ADDR=76.139.106.28:30025
export CONNECT_PASSWORD='tv:user:QxPCZpx6q9cS0P2VzEAMMIkSCWOw0jTyvYaPFS2acjY='

export STEAM_USERNAME=cs2_servers
export STEAM_PASSWORD=Gc2UYVgqHuWdHzugHWpQ


/opt/5stack/scripts/setup-steam-library.sh
/opt/5stack/scripts/run-live-debug.sh