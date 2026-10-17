#!/usr/bin/env bash
# Runs the AMD unit tests: every test/amd/*.sh, or only the files named on the command line.
# Each file runs in its own bash. Exit status is 1 when any file failed.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit 2
if [ $# -gt 0 ]; then
  files=("$@")
else
  files=(test/amd/*.sh)
fi
rc=0
for f in "${files[@]}"; do
  echo "== $f"
  bash "$f" || rc=1
done
exit "$rc"
