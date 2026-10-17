#!/usr/bin/env bash
# S4-U10 wording scan. Host only: it reads git history, which the docker tests do not
# mount. Run it from inside the game-streamer worktree:
#   test/amd/host/wording-scan.sh             findings, then a summary line
#   test/amd/host/wording-scan.sh --list-new  also lists the new log lines for review
# It diffs the working tree (commits, staged and unstaged edits, and the untracked files
# git does not ignore) against the upstream commit the branch last merged,
# `git merge-base HEAD origin/main`, and checks two rules:
#   1. No added line, in any file, holds U+2014. Goldens write upstream's as @EMDASH@.
#   2. Every log line the branch removes from the shipped paths (src/, resources/,
#      motion/ and hud-manager/, which ship in the images) is added back in one of
#      them with the same text, leading and trailing blanks aside: a re-indented or
#      moved upstream log line passes, a reworded or deleted one fails. Log lines are
#      say, log, warn, die, die_failed and die_skipped calls, echo or printf to stderr,
#      C's fprintf(stderr and log_msg(, and console.* calls. moved() lists the upstream
#      lines that leave on purpose.
# A scan cannot tell an NVIDIA log line from an AMD one, so --list-new prints the new
# ones for review; the NVIDIA goldens prove what NVIDIA prints. The list marks S4 C32's
# outro retry line, the one new line NVIDIA can print.
# Exit status: 0 clean, 1 findings, 2 usage error, no merge base or a git failure.
set -euo pipefail

usage() {
  echo "usage: test/amd/host/wording-scan.sh [--list-new]"
}

list_new=0
if [ "$#" -gt 1 ]; then
  usage >&2
  exit 2
fi
case "${1:-}" in
  "") ;;
  --list-new) list_new=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

# Upstream log lines that leave the shipped paths on purpose, trimmed like rule 2's text.
moved() {
  # S3 C14 and S4 C12: stream.sh's LIVE-DIAG line moves into live_diag_line, which adds
  # the enc= field on AMD only; S5-U3 (test/amd/live-diag.sh) proves the NVIDIA text.
  cat <<'EOF'
log "  LIVE-DIAG ${stream_id:0:8}: gpu(util,vramMiB,clkMHz,tempC)=${g} | cs2cpu=${cs2cpu}% capcpu=${capcpu}% (composite=${comp})${adiag}"
EOF
}

repo="$(git rev-parse --show-toplevel)" || exit 2
cd "$repo"
if ! base="$(git merge-base HEAD origin/main 2>/dev/null)"; then
  echo "wording-scan.sh: no merge base with origin/main (git fetch origin first)" >&2
  exit 2
fi

export LC_ALL=C
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
moved > "$tmp/moved"

# One record per added (+) or removed (-) line: KIND, FILE, LINE and TEXT, tab
# separated. The -c settings and the explicit prefixes undo diff options a git config
# can set; the hunk counts tell a removed line that starts with "--" from a header.
if ! git -c core.quotepath=off -c diff.noprefix=false -c diff.mnemonicPrefix=false \
    -c diff.interHunkContext=0 diff --no-color --no-ext-diff --no-textconv -M -U0 \
    --src-prefix=a/ --dst-prefix=b/ "$base" -- > "$tmp/diff"; then
  echo "wording-scan.sh: git diff against $base failed" >&2
  exit 2
fi
awk '
  function path(p) {
    sub(/\t$/, "", p)
    return p == "/dev/null" ? "" : substr(p, 3)
  }
  /^diff --git / { left = 0; right = 0; next }
  left > 0 || right > 0 {
    c = substr($0, 1, 1)
    if (c == "-") { print "-\t" old "\t" ol "\t" substr($0, 2); ol++; left--; next }
    if (c == "+") { print "+\t" new "\t" nl "\t" substr($0, 2); nl++; right--; next }
    if (c == " ") { ol++; nl++; left--; right--; next }
    next
  }
  /^--- / { old = path(substr($0, 5)); next }
  /^\+\+\+ / { new = path(substr($0, 5)); next }
  /^@@ / {
    n = split(substr($2, 2), a, ","); ol = a[1] + 0; left = (n > 1 ? a[2] + 0 : 1)
    n = split(substr($3, 2), b, ","); nl = b[1] + 0; right = (n > 1 ? b[2] + 0 : 1)
  }
' "$tmp/diff" > "$tmp/records"

# Untracked files that git does not ignore count as added, line by line. grep -I skips
# binary files (and empty ones, which hold no lines).
if ! git ls-files -z --others --exclude-standard > "$tmp/untracked"; then
  echo "wording-scan.sh: git ls-files failed" >&2
  exit 2
fi
while IFS= read -r -d '' f; do
  if [ -f "$f" ] && grep -Iq '' "$f"; then
    F="$f" awk '{ print "+\t" ENVIRON["F"] "\t" FNR "\t" $0 }' "$f"
  fi
done < "$tmp/untracked" >> "$tmp/records"

rc=0
DASH="$(printf '\342\200\224')" BASE="$base" LIST_NEW="$list_new" awk '
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  function shipped(f) { return f ~ /^(src|resources|motion|hud-manager)\// }
  function is_log(t) {
    if (t ~ /^(#|\/\/|\/\*)/ || t ~ /^\*([ \t\/]|$)/) return 0
    if (t ~ logre) return 1
    if (t ~ /(^|[^A-Za-z0-9_.-])(echo|printf)[ \t]/ && index(t, ">&2")) return 1
    if (t ~ /fprintf[ \t]*\([ \t]*stderr/ || t ~ /(^|[^A-Za-z0-9_])log_msg[ \t]*\(/) return 1
    return t ~ /console\.(log|warn|error|info|debug)[ \t]*\(/
  }
  function plural(n, w) { return n " " w (n == 1 ? "" : "s") }
  BEGIN {
    logre = "(^|[^A-Za-z0-9_.-])(say|log|warn|die|die_failed|die_skipped)[ \t]+[\"\047]"
    dash = ENVIRON["DASH"]
    c32 = "concat: outro transcode retried with libx264, falling back to re-encode"
  }
  FILENAME == ARGV[1] { moved[$0] = 1; next }
  {
    kind = substr($0, 1, 1); rest = substr($0, 3)
    i = index(rest, "\t"); file = substr(rest, 1, i - 1); rest = substr(rest, i + 1)
    i = index(rest, "\t"); line = substr(rest, 1, i - 1); text = substr(rest, i + 1)
    n++; K[n] = kind; F[n] = file; L[n] = line; T[n] = text
    if (shipped(file)) {
      if (kind == "+") added[trim(text)] = 1
      else removed[trim(text)] = 1
    }
  }
  END {
    for (i = 1; i <= n; i++) {
      t = trim(T[i])
      if (K[i] == "+" && index(T[i], dash)) {
        print F[i] ":" L[i] ": U+2014 in an added line: " t
        bad++
      } else if (K[i] == "-" && shipped(F[i]) && is_log(t) && !(t in added) && !(t in moved)) {
        print F[i] ":" L[i] " (merge base): log line changed or removed: " t
        bad++
      }
      if (K[i] == "+" && shipped(F[i]) && is_log(t) && !(t in removed)) {
        fresh[++nf] = F[i] ":" L[i] ": " t (index(t, c32) ? "   (S4 C32: the one new line NVIDIA can print)" : "")
      }
    }
    if (ENVIRON["LIST_NEW"] == 1 && nf) {
      print "new log lines in the shipped paths:"
      for (i = 1; i <= nf; i++) print "  " fresh[i]
    }
    hint = (nf && ENVIRON["LIST_NEW"] != 1) ? " (listed by --list-new)" : ""
    printf "wording-scan.sh: %s, %s since merge base %s%s\n", plural(bad + 0, "finding"), plural(nf + 0, "new log line"), substr(ENVIRON["BASE"], 1, 12), hint
    exit (bad ? 1 : 0)
  }
' "$tmp/moved" "$tmp/records" || rc=$?
exit "$rc"
