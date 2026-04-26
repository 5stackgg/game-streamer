#!/usr/bin/env bash
# Build and push ghcr.io/5stackgg/game-streamer:latest from the local checkout.
# Useful while on a feature branch, where CI does not push images.
set -euo pipefail

IMAGE="ghcr.io/5stackgg/game-streamer"
CACHE_REF="${IMAGE}:buildcache"
SHA="$(git rev-parse HEAD)"

cd "$(dirname "$0")"

docker buildx build \
  --platform linux/amd64 \
  --push \
  --tag "${IMAGE}:latest" \
  --tag "${IMAGE}:${SHA}" \
  --cache-from "type=registry,ref=${CACHE_REF}" \
  --cache-to "type=registry,ref=${CACHE_REF},mode=max" \
  .
