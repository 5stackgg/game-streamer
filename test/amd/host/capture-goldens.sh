#!/usr/bin/env bash
# Captures the NVIDIA identity goldens of the named test files on the upstream commit the
# branch last merged (git merge-base HEAD origin/main), never on the branch itself:
#
#   test/amd/host/capture-goldens.sh test/amd/xorg-nvidia-identity.sh [more test files]
#
# It checks that commit out in a scratch worktree, copies this checkout's test/amd into
# it, runs the named files there in ubuntu:24.04 with GS_GOLDEN_CAPTURE=1 (the worktree is
# mounted read-write, unlike test/amd/lib/docker.sh), copies their goldens back into
# test/amd/fixtures/goldens/<file name without .sh>/, removes the worktree and shows what
# changed. A changed golden after a merge from origin/main is an upstream change to the
# NVIDIA output: read the upstream commits before committing it.
# Needs git, docker and a current origin/main (git fetch origin first).
set -euo pipefail

if [ $# -eq 0 ]; then
  echo "usage: $0 test/amd/<file>.sh [...]" >&2
  exit 2
fi
repo="$(git rev-parse --show-toplevel)"
cd "$repo"
names=()
for f in "$@"; do
  case "$f" in
    test/amd/*.sh) ;;
    *) echo "not a test/amd test file: $f" >&2; exit 2 ;;
  esac
  if [ ! -f "$f" ]; then
    echo "no such file: $f" >&2
    exit 2
  fi
  names+=("$(basename "$f" .sh)")
done
base="$(git merge-base HEAD origin/main)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/gs-goldens.XXXXXX")"
wt="$tmp/repo"
cleanup() {
  if [ -d "$wt" ]; then
    git -C "$repo" worktree remove --force "$wt"
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
git worktree add --quiet --detach "$wt" "$base"
rm -rf "$wt/test/amd"
mkdir -p "$wt/test"
cp -R "$repo/test/amd" "$wt/test/amd"
for n in "${names[@]}"; do
  rm -rf "$wt/test/amd/fixtures/goldens/$n"
done
docker run --rm --platform linux/amd64 --user "$(id -u):$(id -g)" \
  -e GS_GOLDEN_CAPTURE=1 -v "$wt:/src" -w /src ubuntu:24.04 bash test/amd/lib/run.sh "$@"
mkdir -p "$repo/test/amd/fixtures/goldens"
for n in "${names[@]}"; do
  if [ ! -d "$wt/test/amd/fixtures/goldens/$n" ]; then
    echo "test/amd/$n.sh wrote no goldens" >&2
    exit 1
  fi
  rm -rf "$repo/test/amd/fixtures/goldens/$n"
  cp -R "$wt/test/amd/fixtures/goldens/$n" "$repo/test/amd/fixtures/goldens/$n"
done
echo "goldens captured on $base:"
git status --short test/amd/fixtures/goldens
