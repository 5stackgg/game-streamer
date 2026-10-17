#!/usr/bin/env bash
# Self-test of test/amd/host/wording-scan.sh (S4-U10). Host only, like the scan. Each
# case builds a throwaway git repository under mktemp (upstream commit as origin/main,
# feature/amd-gpu checked out), with HOME and the git config isolated, so the checkout
# this file sits in is never touched. Runs with the bash 3.2 and BSD tools of macOS.
# Run from the worktree root: test/amd/host/wording-scan-test.sh
# The fixtures quote shell code, so their $ signs stay literal on purpose.
# shellcheck disable=SC2016
set -uo pipefail

scan="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wording-scan.sh"
work="$(mktemp -d)" || exit 1
trap 'rm -rf "$work"' EXIT

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export HOME="$work/home" XDG_CONFIG_HOME="$work/xdg" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=wording-test GIT_AUTHOR_EMAIL=wording-test@localhost
export GIT_COMMITTER_NAME=wording-test GIT_COMMITTER_EMAIL=wording-test@localhost
mkdir -p "$HOME" "$XDG_CONFIG_HOME"

DASH="$(printf '\342\200\224')"
passed=0
failed=0
name=""
out=""
rc=0

# put FILE: writes stdin to FILE, @DASH@ becoming U+2014.
put() {
  local text
  mkdir -p "$(dirname "$1")"
  text="$(cat)"
  printf '%s\n' "${text//@DASH@/$DASH}" > "$1"
}

# swap FILE OLD [NEW...]: replaces the one line equal to OLD with the NEW lines (no NEW
# deletes it). @DASH@ becomes U+2014 in OLD and NEW.
swap() {
  local file="$1" old="$2" new=""
  shift 2
  if [ "$#" -gt 0 ]; then
    new="$(printf '%s\n' "$@")"
  fi
  OLD="${old//@DASH@/$DASH}" NEW="${new//@DASH@/$DASH}" N="$#" awk '
    $0 == ENVIRON["OLD"] { hits++; if (ENVIRON["N"] + 0 > 0) print ENVIRON["NEW"]; next }
    { print }
    END { exit (hits == 1 ? 0 : 1) }
  ' "$file" > "$file.swap" || {
    echo "setup [$name]: '$old' is not exactly one line of $file" >&2
    exit 1
  }
  mv "$file.swap" "$file"
}

commit() {
  git add -A && git commit -q -m "$1" || exit 1
}

# The upstream tree. Line numbers matter: the cases name them.
upstream_files() {
  put src/lib/enc.sh <<'EOF'
#!/usr/bin/env bash
# encoder helpers (wording scan fixture)
pick() {
  local codec="$1"
  if [ "$codec" = h265 ]; then
    say "h265 requested @DASH@ checking the encoder"
    log "  encoder: nvh265enc"
  fi
  warn "fallback to h264"
  echo "pick: no encoder" >&2
}
diag() {
  log "  LIVE-DIAG ${stream_id:0:8}: gpu(util,vramMiB,clkMHz,tempC)=${g} | cs2cpu=${cs2cpu}% capcpu=${capcpu}% (composite=${comp})${adiag}"
}
# warn "this comment looks like a log line"
case "$1" in
  *) die "unknown mode: $1" ;;
esac
EOF
  put src/vk.c <<'EOF'
#include <stdio.h>
int main(void) {
  fprintf(stderr, "vk: capture started\n");
  log_msg("cuda init failed, using the host map");
  return 0;
}
EOF
  put src/ui.mjs <<'EOF'
console.error("ui: no frames");
EOF
  put README.md <<'EOF'
# fixture @DASH@ upstream text the branch keeps
EOF
}

# mkrepo DIR: a fresh repository in $work/DIR, holding upstream_files as origin/main and
# with feature/amd-gpu checked out; the shell then works inside it.
mkrepo() {
  cd "$work" || exit 1
  git -c init.defaultBranch=main init -q "$1" || exit 1
  cd "$1" || exit 1
  upstream_files
  commit upstream
  git update-ref refs/remotes/origin/main HEAD || exit 1
  git checkout -q -b feature/amd-gpu || exit 1
}

# run_scan [ARGS...]: runs the scan in the current directory; sets out and rc.
run_scan() {
  out="$("$scan" "$@" 2>&1)"
  rc=$?
}

verdict() {
  if [ -z "$1" ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL [%s]: %s\n' "$name" "$1"
    printf '%s\n' "$out" | sed 's/^/    | /'
  fi
}

# expect RC TEXT...: the last scan exited with RC and printed every TEXT.
expect() {
  local want="$1" t bad=""
  shift
  [ "$rc" = "$want" ] || bad="exit status $rc, want $want"
  for t in "$@"; do
    case "$out" in
      *"$t"*) ;;
      *) bad="${bad:+$bad; }output lacks: $t" ;;
    esac
  done
  verdict "$bad"
}

# lacks TEXT...: the last scan printed none of the TEXTs.
lacks() {
  local t bad=""
  for t in "$@"; do
    case "$out" in
      *"$t"*) bad="${bad:+$bad; }output holds: $t" ;;
    esac
  done
  verdict "$bad"
}

name="clean branch: a new AMD log line, a golden with @EMDASH@"
mkrepo clean
put src/lib/amd.sh <<'EOF'
#!/usr/bin/env bash
va_pick() {
  if [ "${GS_GPU_VENDOR:-}" = amd ]; then
    warn "no VA-API HEVC encoder is usable, falling back to h264"
  fi
}
EOF
put test/amd/fixtures/goldens/enc/say.txt <<'EOF'
h265 requested @EMDASH@ checking the encoder
EOF
commit "amd lines"
run_scan
expect 0 "0 findings, 1 new log line since merge base" "(listed by --list-new)"

name="U+2014 in an added code line"
mkrepo dash-code
put src/lib/amd.sh <<'EOF'
#!/usr/bin/env bash
say "va: probing @DASH@ please wait"
EOF
commit "dash"
run_scan
expect 1 "src/lib/amd.sh:2: U+2014 in an added line" "1 finding, "

name="U+2014 in an added golden"
mkrepo dash-golden
put test/amd/fixtures/goldens/enc/say.txt <<'EOF'
h265 requested @DASH@ checking the encoder
EOF
commit "golden"
run_scan
expect 1 "test/amd/fixtures/goldens/enc/say.txt:1: U+2014 in an added line"

name="U+2014 in an untracked text file, binary files skipped"
mkrepo dash-untracked
put src/lib/new.sh <<'EOF'
#!/usr/bin/env bash
# draft @DASH@ not added yet
EOF
printf 'bin\000\342\200\224\n' > src/blob.bin
run_scan
expect 1 "src/lib/new.sh:2: U+2014 in an added line"
lacks "blob.bin"

name="U+2014 in an unstaged edit"
mkrepo dash-unstaged
swap src/lib/enc.sh '  warn "fallback to h264"' '  warn "fallback to h264"' '  : "note @DASH@ unstaged"'
run_scan
expect 1 "src/lib/enc.sh:10: U+2014 in an added line"

name="re-indented upstream line holding U+2014"
mkrepo dash-reindent
swap src/lib/enc.sh '    say "h265 requested @DASH@ checking the encoder"' '      say "h265 requested @DASH@ checking the encoder"'
commit "re-indent"
run_scan
expect 1 "src/lib/enc.sh:6: U+2014 in an added line"
lacks "log line changed"

name="changed upstream log strings"
mkrepo changed
swap src/lib/enc.sh '  warn "fallback to h264"' '  warn "falling back to h264"'
swap src/lib/enc.sh '  *) die "unknown mode: $1" ;;' '  *) die "unknown mode $1" ;;'
commit "reword"
run_scan
expect 1 'src/lib/enc.sh:9 (merge base): log line changed or removed: warn "fallback to h264"' \
  'src/lib/enc.sh:17 (merge base): log line changed or removed: *) die "unknown mode: $1" ;;' \
  "2 findings, "

name="removed stderr echo"
mkrepo removed
swap src/lib/enc.sh '  echo "pick: no encoder" >&2'
commit "remove"
run_scan
expect 1 'src/lib/enc.sh:10 (merge base): log line changed or removed: echo "pick: no encoder" >&2'

name="log line moved to another file and re-indented"
mkrepo moved
swap src/lib/enc.sh '    log "  encoder: nvh265enc"'
put src/lib/moved.sh <<'EOF'
#!/usr/bin/env bash
log "  encoder: nvh265enc"
EOF
commit "move"
run_scan
expect 0 "0 findings, 0 new log lines"

name="renamed upstream file keeps its U+2014 lines out"
mkrepo renamed
git mv src/lib/enc.sh src/lib/encoder.sh || exit 1
commit "rename"
run_scan
expect 0 "0 findings, 0 new log lines"
lacks "U+2014"

name="LIVE-DIAG line moved into live_diag_line"
mkrepo live-diag
swap src/lib/enc.sh '  log "  LIVE-DIAG ${stream_id:0:8}: gpu(util,vramMiB,clkMHz,tempC)=${g} | cs2cpu=${cs2cpu}% capcpu=${capcpu}% (composite=${comp})${adiag}"' \
  '  log "$(live_diag_line "$stream_id" "$g" "$cs2cpu" "$capcpu" "$comp" "$adiag" "$enc")"'
commit "live diag"
run_scan
expect 0 "0 findings, 1 new log line"

name="C and JavaScript log strings"
mkrepo c-js
swap src/vk.c '  fprintf(stderr, "vk: capture started\n");' '  fprintf(stderr, "vk: capture started (VA)\n");'
swap src/vk.c '  log_msg("cuda init failed, using the host map");' '  log_msg("cuda init failed");'
swap src/ui.mjs 'console.error("ui: no frames");' 'console.error("ui: no frames yet");'
commit "strings"
run_scan
expect 1 "src/vk.c:3 (merge base): log line changed or removed" \
  "src/vk.c:4 (merge base): log line changed or removed" \
  "src/ui.mjs:1 (merge base): log line changed or removed" "3 findings, "

name="--list-new lists the new log lines and marks S4 C32"
mkrepo list-new
put src/lib/amd.sh <<'EOF'
#!/usr/bin/env bash
va_note() {
  warn "no VA-API HEVC encoder is usable, falling back to h264"
  echo "va: stdout only"
      say "  concat: outro transcode retried with libx264, falling back to re-encode"
}
EOF
swap src/lib/enc.sh '    log "  encoder: nvh265enc"' '      log "  encoder: nvh265enc"'
commit "new lines"
run_scan --list-new
expect 0 'src/lib/amd.sh:3: warn "no VA-API HEVC encoder is usable, falling back to h264"' \
  'src/lib/amd.sh:5: say "  concat: outro transcode retried with libx264, falling back to re-encode"   (S4 C32' \
  "0 findings, 2 new log lines since merge base"
lacks "va: stdout only" "nvh265enc" "(listed by --list-new)"

name="comments and plain code lines are not log lines"
mkrepo comments
swap src/lib/enc.sh '# warn "this comment looks like a log line"' '# warn "this comment was reworded"'
swap src/lib/enc.sh '  local codec="$1"' '  local codec="${1:-h264}"'
commit "comments"
run_scan
expect 0 "0 findings, 0 new log lines"

name="diff settings in the git config, scan run from a subdirectory"
mkrepo config
git config diff.noprefix true
git config diff.mnemonicPrefix true
git config diff.interHunkContext 10
git config diff.relative true
git config diff.external false
git config color.ui always
git config core.quotepath true
swap src/lib/enc.sh '    say "h265 requested @DASH@ checking the encoder"' '      say "h265 requested @DASH@ checking the encoder"'
swap src/lib/enc.sh '  warn "fallback to h264"' '  warn "falling back to h264"'
commit "config"
cd src/lib || exit 1
run_scan
expect 1 "src/lib/enc.sh:6: U+2014 in an added line" \
  'src/lib/enc.sh:9 (merge base): log line changed or removed: warn "fallback to h264"' "2 findings, "

name="no origin/main"
mkrepo no-base
git update-ref -d refs/remotes/origin/main || exit 1
run_scan
expect 2 "no merge base with origin/main"

name="unknown option"
mkrepo usage
run_scan --bogus
expect 2 "usage: test/amd/host/wording-scan.sh [--list-new]"

echo "wording-scan-test.sh: $passed passed, $failed failed"
[ "$failed" = 0 ]
