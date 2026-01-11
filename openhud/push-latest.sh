#!/usr/bin/env bash
# Build and push ghcr.io/5stackgg/openhud from the local openhud/ context.
#
# OpenHud is consumed by game-streamer's Dockerfile via
# `COPY --from=ghcr.io/5stackgg/openhud:<tag>`. This script builds the
# Linux unpacked Electron output and publishes it as :latest plus the
# pinned OPENHUD_REF (so game-streamer can pin a specific HUD version
# via --build-arg OPENHUD_IMAGE=ghcr.io/5stackgg/openhud:<ref>).
#
# Usage:
#   ./push-latest.sh                            # build upstream main, push :latest + :main
#   OPENHUD_REF=v3.0.7 ./push-latest.sh         # pin a tag
#   OPENHUD_REPO=5stackgg/OpenHud OPENHUD_REF=foo ./push-latest.sh
set -euo pipefail

IMAGE="ghcr.io/5stackgg/openhud"
CACHE_REF="${IMAGE}:buildcache"

OPENHUD_REPO="${OPENHUD_REPO:-JohnTimmermann/OpenHud}"
OPENHUD_REF="${OPENHUD_REF:-main}"

# Sanitize the ref for use as a docker tag: replace anything that isn't
# in [A-Za-z0-9._-] with `-`. Tags like `feature/foo` or refs/heads/...
# would otherwise be rejected by the registry.
REF_TAG="$(printf '%s' "$OPENHUD_REF" | tr -c 'A-Za-z0-9._-' '-')"

cd "$(dirname "$0")"

echo "building $IMAGE from $OPENHUD_REPO @ $OPENHUD_REF"
echo "  -> tags: ${IMAGE}:latest ${IMAGE}:${REF_TAG}"

docker buildx build \
  --platform linux/amd64 \
  --push \
  --build-arg "OPENHUD_REPO=${OPENHUD_REPO}" \
  --build-arg "OPENHUD_REF=${OPENHUD_REF}" \
  --tag "${IMAGE}:latest" \
  --tag "${IMAGE}:${REF_TAG}" \
  --cache-from "type=registry,ref=${CACHE_REF}" \
  --cache-to "type=registry,ref=${CACHE_REF},mode=max" \
  .

echo
echo "done. pin in game-streamer with:"
echo "  docker build --build-arg OPENHUD_IMAGE=${IMAGE}:${REF_TAG} ."
