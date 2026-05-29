#!/usr/bin/env bash
# Build and push ghcr.io/5stackgg/game-streamer from the local checkout.
# Useful while on a feature branch, where CI does not push images.
#
# Usage:
#   ./push-latest.sh           # -> :latest  (+ :<sha>)
#   ./push-latest.sh dev       # -> :dev     (+ :<sha>)  test image
#   ./push-latest.sh dev rc    # -> :dev :rc (+ :<sha>)
#
# The :<sha> tag is always added so a pushed image is traceable back to a
# commit even when the named tag is mutable.
set -euo pipefail

IMAGE="ghcr.io/5stackgg/game-streamer"
CACHE_REF="${IMAGE}:buildcache"
SHA="$(git rev-parse HEAD)"

# Tags: positional args, or $TAGS, defaulting to "latest".
if [ "$#" -gt 0 ]; then
  TAGS=( "$@" )
else
  # shellcheck disable=SC2206  # intentional word-split of $TAGS
  TAGS=( ${TAGS:-latest} )
fi

cd "$(dirname "$0")"

tag_args=()
for t in "${TAGS[@]}"; do
  tag_args+=( --tag "${IMAGE}:${t}" )
done
tag_args+=( --tag "${IMAGE}:${SHA}" )

echo "building + pushing ${IMAGE} with tags: ${TAGS[*]} ${SHA}"
docker buildx build \
  --platform linux/amd64 \
  --push \
  "${tag_args[@]}" \
  --cache-from "type=registry,ref=${CACHE_REF}" \
  --cache-to "type=registry,ref=${CACHE_REF},mode=max" \
  .
