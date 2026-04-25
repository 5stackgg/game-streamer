#!/usr/bin/env bash
# Smoke test for src/game-streamer.sh's operator CLI.
# Asserts:
#   1. `help` exits 0 and prints the doc block (mentions MODE=).
#   2. Unknown subcommand exits 2 and lists the known set.
#   3. Every entry in the script's SUBCOMMANDS array routes to a real
#      target — either an executable file under src/dev/ or a function
#      defined in game-streamer.sh.
#
# Designed to run anywhere with bash + grep + awk; no Steam/Xorg/CS2.
# CI invokes this from the repo root.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY="$REPO_DIR/src/game-streamer.sh"

pass=0
fail=0
report() {
  local outcome="$1"; local name="$2"
  if [ "$outcome" = "ok" ]; then
    printf '  ok   %s\n' "$name"
    pass=$(( pass + 1 ))
  else
    printf '  FAIL %s\n' "$name" >&2
    fail=$(( fail + 1 ))
  fi
}

# ---- 1. help -----------------------------------------------------------
out=$("$ENTRY" help 2>&1)
rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'MODE='; then
  report ok "help exits 0 and mentions MODE="
else
  report fail "help (rc=$rc, output=$out)"
fi

# ---- 2. unknown subcommand --------------------------------------------
set +e
out=$("$ENTRY" __nonsense__ 2>&1)
rc=$?
set -e
if [ $rc -eq 2 ] \
   && printf '%s' "$out" | grep -q 'unknown subcommand' \
   && printf '%s' "$out" | grep -q 'state' \
   && printf '%s' "$out" | grep -q 'help'; then
  report ok "unknown subcommand exits 2 and lists known commands"
else
  report fail "unknown subcommand error (rc=$rc, output=$out)"
fi

# ---- 3. every SUBCOMMANDS entry resolves -------------------------------
# Pull the array entries straight out of the script. Single-quoted
# entries on lines like:   "name:target"
mapfile -t entries < <(awk '
  /^SUBCOMMANDS=\(/ { in_block = 1; next }
  in_block && /^\)/ { in_block = 0; exit }
  in_block          { gsub(/^[[:space:]]*"|"[[:space:]]*$/, ""); print }
' "$ENTRY")

if [ "${#entries[@]}" -eq 0 ]; then
  report fail "could not parse SUBCOMMANDS array out of $ENTRY"
else
  report ok "parsed ${#entries[@]} SUBCOMMANDS entries"
fi

for entry in "${entries[@]}"; do
  name="${entry%%:*}"
  target="${entry#*:}"

  if [ "${target#dev/}" != "$target" ]; then
    # script target — check the file is an executable bash script.
    script="$REPO_DIR/src/$target"
    if [ -x "$script" ] && bash -n "$script" 2>/dev/null; then
      report ok "$name → $target exists and parses"
    else
      report fail "$name → $target missing or invalid"
    fi
  else
    # function target — check the script defines it.
    if grep -qE "^${target}\(\)" "$ENTRY"; then
      report ok "$name → $target() defined"
    else
      report fail "$name → $target() not defined in $ENTRY"
    fi
  fi
done

echo
printf 'cli.sh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
