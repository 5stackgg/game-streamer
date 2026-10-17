#!/usr/bin/env bash
# Runs test/amd/lib/run.sh in ubuntu:24.04 for linux/amd64 (the image's Ubuntu release and
# architecture, bash 5), with the repo mounted read-only. Arguments go to run.sh: test
# files relative to the repo root, for example test/amd/gpu-env.sh.
set -eu
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec docker run --rm --platform linux/amd64 -v "$repo:/src:ro" -w /src ubuntu:24.04 bash test/amd/lib/run.sh "$@"
