# =============================================================================
# OpenHud (CS2 spectator HUD) — standalone, versioned image.
#
# Upstream JohnTimmermann/OpenHud only publishes Windows artifacts. We build
# the Linux x64 `linux-unpacked` Electron-builder output ourselves here and
# publish the result as ghcr.io/5stackgg/openhud:<tag>. game-streamer's
# Dockerfile pulls from this image via `COPY --from=ghcr.io/5stackgg/openhud:...`
# so OpenHud versions independently of the streamer.
#
# Build:
#   docker build -t ghcr.io/5stackgg/openhud:v3.0.7 \
#     --build-arg OPENHUD_REPO=JohnTimmermann/OpenHud \
#     --build-arg OPENHUD_REF=main \
#     openhud/
#
# Publish:
#   docker push ghcr.io/5stackgg/openhud:v3.0.7
#   docker tag  ghcr.io/5stackgg/openhud:v3.0.7 ghcr.io/5stackgg/openhud:latest
#   docker push ghcr.io/5stackgg/openhud:latest
#
# Then rebuild game-streamer with:
#   docker build --build-arg OPENHUD_IMAGE=ghcr.io/5stackgg/openhud:v3.0.7 .
# =============================================================================

# ---- Stage 1: build the Electron app ----------------------------------------
FROM node:22-bookworm AS builder

ARG DEBIAN_FRONTEND=noninteractive
ARG OPENHUD_REPO=JohnTimmermann/OpenHud
ARG OPENHUD_REF=main

# sqlite3 is a node-gyp native build → needs python3 + a C++ toolchain.
# git fetches the source at the requested ref without baking a tarball
# URL into the image.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git python3 make g++ ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 --branch "$OPENHUD_REF" \
      "https://github.com/${OPENHUD_REPO}.git" . \
      || (git clone "https://github.com/${OPENHUD_REPO}.git" . \
          && git checkout "$OPENHUD_REF")

# Patch: OpenHud only opens the spectator HUD BrowserWindow when an
# admin clicks "Start Overlay" via IPC. There's no external trigger,
# so a headless container can't get the HUD on screen. The patch adds
# an OPENHUD_AUTO_OVERLAY=1 env-gated auto-open on app-ready. Tracked
# at openhud/auto-overlay.patch in the game-streamer repo.
COPY auto-overlay.patch /tmp/auto-overlay.patch
RUN git apply --verbose /tmp/auto-overlay.patch \
 && rm /tmp/auto-overlay.patch

# Make the spectator HUD non-focusable + neutralize its focus-grab +
# pin its dimensions to the capture resolution.
#
# Three upstream behaviors fight us when we want cs2 to hold keyboard
# focus (which is required because cs2 filters XSendEvent, so our
# spec-server's keystrokes only reach cs2 via XTest -> focused window):
#
#   1. createHudWindow sets `focusable: true` explicitly. Even with
#      cs2 activated, nothing prevents the WM/Electron from handing
#      focus back to the overlay later.
#   2. Worse, hudWindow.on("show", ...) schedules a hudWindow.focus()
#      200ms after every show(). Any /api/overlay/start (boot, admin
#      "Overlay" button) re-creates the BrowserWindow, the show event
#      fires, and 200ms later the overlay actively steals focus from
#      cs2 — observed live in pod, the autodirector/spec keys stop
#      working immediately after a HUD recreation.
#   3. Once focusable: false is set, Openbox refuses to apply
#      _NET_WM_STATE_FULLSCREEN to the window (the WM treats fullscreen
#      as a focused-window operation). The BrowserWindow then defaults
#      to Electron's ~800x600 window size at (0,0), and the HUD's
#      absolutely-positioned elements end up clipped to that corner.
#      Observed live: only the bottom-left team panel showed in the
#      capture, everything else outside the 800x600 box was missing.
#
# Fix:
#   * flip focusable to false (overlay can never take keyboard focus)
#   * remove the .focus() refocus call (no fight after each show())
#   * import Electron's `screen` module and spread the primary display
#     bounds into the BrowserWindow options, so the window is sized to
#     whatever the X display actually is (1920x1080, 1280x720, etc.).
#
# Spreading `screen.getPrimaryDisplay().bounds` works because Electron's
# Display.bounds is `{x, y, width, height}` — the four BrowserWindow
# options we need. No hardcoded resolution: if the capture pipeline
# runs at a different resolution later, the HUD picks it up
# automatically as long as the X display matches.
#
# Done as sed-injection (rather than a real patch hunk) so it stays
# robust against unrelated upstream churn. Each step is guarded with
# a verify-grep that exits 1 if the expected pattern is missing or
# the post-edit state isn't right — better to fail the build than
# ship a silently-broken overlay.
RUN HUD_FILE=src/electron/hudWindow.ts; \
    test -f "$HUD_FILE" \
      || { echo "ERROR: $HUD_FILE not found — upstream openhud layout changed" >&2; exit 1; }; \
    grep -q 'focusable: true' "$HUD_FILE" \
      || { echo "ERROR: 'focusable: true' marker not found in $HUD_FILE — upstream changed the option, review patch" >&2; exit 1; }; \
    sed -i 's/focusable: true,/focusable: false,/' "$HUD_FILE"; \
    grep -q 'focusable: false' "$HUD_FILE" \
      || { echo "ERROR: focusable flip failed verification" >&2; exit 1; }; \
    grep -q 'hudWindow?\.focus()' "$HUD_FILE" \
      || { echo "ERROR: 'hudWindow?.focus()' refocus call not found — upstream changed it, review patch" >&2; exit 1; }; \
    sed -i 's|hudWindow?\.focus();|/* removed by game-streamer patch — see openhud/Dockerfile */|' "$HUD_FILE"; \
    grep -q 'removed by game-streamer patch' "$HUD_FILE" \
      || { echo "ERROR: focus-call removal failed verification" >&2; exit 1; }; \
    grep -qE 'import \{ BrowserWindow \} from "electron";' "$HUD_FILE" \
      || { echo "ERROR: expected import line 'import { BrowserWindow } from \"electron\";' not found — upstream changed it, review patch" >&2; exit 1; }; \
    sed -i 's|import { BrowserWindow } from "electron";|import { BrowserWindow, screen } from "electron";|' "$HUD_FILE"; \
    grep -q 'BrowserWindow, screen' "$HUD_FILE" \
      || { echo "ERROR: screen-import injection failed verification" >&2; exit 1; }; \
    grep -q 'fullscreen: true' "$HUD_FILE" \
      || { echo "ERROR: 'fullscreen: true' marker not found in $HUD_FILE — upstream changed the option, review patch" >&2; exit 1; }; \
    sed -i 's|fullscreen: true,|fullscreen: true,\n        ...screen.getPrimaryDisplay().bounds,|' "$HUD_FILE"; \
    grep -q '\.\.\.screen\.getPrimaryDisplay()\.bounds' "$HUD_FILE" \
      || { echo "ERROR: display-bounds spread injection failed verification" >&2; exit 1; }; \
    echo "patched $HUD_FILE: HUD overlay is non-focusable, never re-grabs focus on show, and sized to the primary display"

ENV ELECTRON_BUILDER_CACHE=/tmp/eb-cache \
    ELECTRON_CACHE=/tmp/electron-cache

RUN npm ci --no-audit --no-fund

# `dist:linux` runs: tsc transpile of the Electron entry, vite build of
# the renderer, then electron-builder --linux --x64. Output lands in
# dist/linux-unpacked/ (the directory that `openhud` runs from).
RUN npm run dist:linux \
 && test -x dist/linux-unpacked/openhud \
 && rm -rf /tmp/eb-cache /tmp/electron-cache

# Locate the GSI cfg so it lives at a stable path in the final image.
RUN mkdir -p /out/openhud /out/openhud/assets \
 && cp -a dist/linux-unpacked/. /out/openhud/ \
 && (find . -name 'gamestate_integration_openhud.cfg' -type f \
       -exec cp {} /out/openhud/assets/ \; ; true)

# ---- Stage 2: publishable image ---------------------------------------------
# `scratch` would be ideal for a pure-payload image, but BuildKit's
# remote `COPY --from=<image>` against a scratch image can be flaky on
# older Docker daemons. Stick with a tiny base.
FROM debian:bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/5stackgg/game-streamer"
LABEL org.opencontainers.image.description="OpenHud Linux unpacked build, consumed by game-streamer via COPY --from"
LABEL org.opencontainers.image.licenses="MIT"

COPY --from=builder /out/openhud /opt/openhud
RUN chmod +x /opt/openhud/openhud

# This image is not meant to run on its own — game-streamer COPY --from's
# /opt/openhud out of it. If someone does `docker run` it, print the
# layout so they immediately see what's here.
CMD ["sh", "-c", "ls -la /opt/openhud /opt/openhud/assets"]
