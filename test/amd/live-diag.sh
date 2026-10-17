# S5-U3 (an S3 C14 amendment): the LIVE-DIAG line that start_capture's sampler logs every
# GS_LIVE_DIAG_INTERVAL seconds (src/lib/stream.sh). The NVIDIA goldens hold upstream's
# text for fixed inputs. The line is cut out of stream.sh by its anchor text (exactly one
# line must hold it) and evaluated after sourcing stream.sh, with log printing its
# arguments and the sampler's variables set to the inputs.
# shellcheck shell=bash source-path=SCRIPTDIR
# shellcheck disable=SC2016  # the t_run script expands in the child shell
# shellcheck source=lib/harness.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"
# shellcheck source=lib/golden.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/golden.sh"

DIAG_ANCHOR='log "  LIVE-DIAG ${stream_id:0:8}:'
# The compare run cuts the builder's call site instead, so it runs the new code with the
# same inputs (S5-U3).
DIAG_CALL='log "$(live_diag_line '
NV_ENC='nvcudah264enc preset=p4 tune=ultra-low-latency rate-control=cbr gop-size=60 bitrate=8000'
UUID=8f14e45f-ceea-467f-a0e6-0d0b1d2c3e4f

# diag_cut ANCHOR: prints the one line of src/lib/stream.sh that holds ANCHOR, and fails
# when no line or more than one holds it.
diag_cut() {
  local file="$GS_REPO/src/lib/stream.sh" n
  n=$(grep -c -F -- "$1" "$file")
  if [ "$n" != 1 ]; then
    echo "diag_cut: [$1] matched $n lines in $file" >&2
    return 1
  fi
  grep -F -- "$1" "$file"
}

# diag_run [VAR=VALUE ...]: evaluates the LIVE-DIAG line with the inputs D_ID (stream_id),
# D_G (g), D_CS2CPU, D_CAPCPU, D_COMP, D_ADIAG and D_ENC (the start_capture local enc)
# given as pairs, plus any other pairs. T_STDOUT is the printed text. Fails the case and
# returns 1 when the line cannot be cut out.
diag_run() {
  local anchor="$DIAG_ANCHOR"
  t_capture_mode || anchor="$DIAG_CALL"
  if ! diag_cut "$anchor" > "$T_TMP/diag.sh"; then
    _t_bad "cannot cut the LIVE-DIAG line out of src/lib/stream.sh"
    return 1
  fi
  t_run "$@" -- 'set -uo pipefail
. "$GS_REPO/src/lib/stream.sh"
log() { printf "%s\n" "$*"; }
stream_id=$D_ID g=$D_G cs2cpu=$D_CS2CPU capcpu=$D_CAPCPU comp=$D_COMP adiag=$D_ADIAG
enc=$D_ENC
eval "$(cat "$T_TMP/diag.sh")"'
}

# diag_golden NAME KEY [VAR=VALUE ...]: a case that runs diag_run with the pairs and
# compares the text with the golden KEY.
diag_golden() {
  local key="$2"
  t_case "$1"
  shift 2
  diag_run "$@" || return 0
  assert_rc 0 "$key: the line evaluates"
  assert_empty "$T_STDERR" "$key: nothing on stderr"
  t_golden "$key" "$T_STDOUT"
}

golden_live_diag() {
  diag_golden "unset vendor: audio, the composite path" live-diag-unset-audio \
    D_ID="$UUID" D_G=45,1234,1800,60 D_CS2CPU=85 D_CAPCPU=43 D_COMP=1 \
    D_ADIAG=' | audio srcout=12ms sinkin=8ms' D_ENC="$NV_ENC"
  diag_golden "unset vendor: video only, nothing sampled" live-diag-unset-empty \
    D_ID="$UUID" D_G= D_CS2CPU='?' D_CAPCPU='?' D_COMP=0 D_ADIAG= D_ENC="$NV_ENC"
  diag_golden "nvidia: a short stream id, unknown audio latencies" live-diag-nvidia-short-id \
    GS_GPU_VENDOR=nvidia D_ID=demo-7 D_G=100,24564,2805,83 D_CS2CPU=312 D_CAPCPU=0 \
    D_COMP=0 D_ADIAG=' | audio srcout=?ms sinkin=?ms' \
    D_ENC='x264enc tune=zerolatency speed-preset=veryfast bitrate=8000 key-int-max=60'
}

golden_live_diag
if t_capture_mode; then t_done; fi

# S5-U3, AMD half: the builder with a stubbed sampler. The AMD line carries the sampler's
# five fields as it prints them ('?' included) and ends with enc= and the first word of the
# encoder string in use (S4-D16).
AMD_ADDR=0000:c6:00.0
VA_ENC='vah264enc rate-control=vbr target-percentage=95 bitrate=8000 cpb-size=8000 key-int-max=60 b-frames=0 ref-frames=1 target-usage=4'
X264_ENC='x264enc tune=zerolatency speed-preset=veryfast bitrate=8000 key-int-max=60'

# amd_line [VAR=VALUE ...]: sources stream.sh as an AMD pod does, replaces gs_gpu_sample
# with a function that prints D_SAMPLE, and prints the builder's line for the inputs D_ID,
# D_CS2CPU, D_CAPCPU, D_COMP, D_ADIAG and D_ENC.
amd_line() {
  t_fake_gpu "$AMD_ADDR" 0x1002 0x1586 0x038000 renderD128
  t_run GS_GPU_VENDOR=amd GS_GPU_PCI_ADDRESS="$AMD_ADDR" "$@" -- 'set -uo pipefail
. "$GS_REPO/src/lib/stream.sh"
gs_gpu_sample() { printf "%s\n" "$D_SAMPLE"; }
live_diag_line "$D_ID" "$(gs_gpu_sample)" "$D_CS2CPU" "$D_CAPCPU" "$D_COMP" "$D_ADIAG" "$D_ENC"'
}

t_case "S5-U3 amd: the sampler fields, audio and the VA encoder word"
amd_line D_ID="$UUID" D_SAMPLE='util=37 vramMiB=2210 clkMHz=2900 tempC=58 vcn=12' \
  D_CS2CPU=96 D_CAPCPU=51 D_COMP=1 D_ADIAG=' | audio srcout=12ms sinkin=8ms' D_ENC="$VA_ENC"
assert_rc 0 "the builder runs"
assert_empty "$T_STDERR" "nothing on stderr"
assert_eq "  LIVE-DIAG 8f14e45f: gpu util=37 vramMiB=2210 clkMHz=2900 tempC=58 vcn=12 | cs2cpu=96% capcpu=51% (composite=1) | audio srcout=12ms sinkin=8ms | enc=vah264enc" \
  "$T_STDOUT" "the AMD line"

t_case "S5-U3 amd: '?' passes through, video only, the x264enc fallback"
amd_line D_ID=demo-7 D_SAMPLE='util=? vramMiB=? clkMHz=? tempC=? vcn=?' \
  D_CS2CPU='?' D_CAPCPU='?' D_COMP=0 D_ADIAG= D_ENC="$X264_ENC"
assert_rc 0 "the builder runs"
assert_empty "$T_STDERR" "nothing on stderr"
assert_eq "  LIVE-DIAG demo-7: gpu util=? vramMiB=? clkMHz=? tempC=? vcn=? | cs2cpu=?% capcpu=?% (composite=0) | enc=x264enc" \
  "$T_STDOUT" "the AMD line with unknown values"

# The sampler block of start_capture (from the GS_LIVE_DIAG gate through its closing fi),
# cut out of stream.sh and evaluated after sourcing it. pgrep finds no cs2 and pactl answers
# nothing, so the audio latencies are '?' (cs2cpu reads as 0 or '?').
DIAG_GATE='  if [ "${GS_LIVE_DIAG:-1}" = "1" ]'
AMD_LINE_RE='^  LIVE-DIAG 8f14e45f: gpu util=37 vramMiB=2210 clkMHz=2900 tempC=58 vcn=12 \| cs2cpu=([0-9]+|\?)% capcpu=([0-9]+|\?)% \(composite=1\) \| audio srcout=\?ms sinkin=\?ms \| enc=x264enc$'

# block_cut: prints the lines of src/lib/stream.sh from the line that starts with DIAG_GATE
# through the first line after it that is exactly "  fi". Fails unless exactly one line
# starts with DIAG_GATE.
block_cut() {
  awk -v gate="$DIAG_GATE" '
    index($0, gate) == 1 { n++; on = 1 }
    on { print }
    on && $0 == "  fi" { on = 0 }
    END { exit (n == 1 ? 0 : 1) }' "$GS_REPO/src/lib/stream.sh"
}

# block_run [VAR=VALUE ...]: runs the cut block with the pairs, audio on, the composite path
# and GS_LIVE_DIAG_INTERVAL=0.2, under a capture pid (a sleep). log prints its arguments and
# then ends the capture pid, so a sampler logs one line and exits; the run waits for it.
# Fails the case and returns 1 when the block cannot be cut out.
block_run() {
  if ! block_cut > "$T_TMP/block.sh"; then
    _t_bad "cannot cut the sampler block out of src/lib/stream.sh"
    return 1
  fi
  t_stub pgrep 'exit 1'
  t_stub pactl 'exit 1'
  t_run GS_LIVE_DIAG_INTERVAL=0.2 "$@" -- 'set -uo pipefail
. "$GS_REPO/src/lib/stream.sh"
log() { printf "%s\n" "$*"; kill "$pid" 2>/dev/null; }
gs_gpu_sample() { printf "%s\n" "util=37 vramMiB=2210 clkMHz=2900 tempC=58 vcn=12"; }
stream_id=8f14e45f-ceea-467f-a0e6-0d0b1d2c3e4f used_composite=1 audio=1
enc="x264enc tune=zerolatency speed-preset=veryfast bitrate=8000 key-int-max=60"
sleep 10 &
pid=$!
eval "$(cat "$T_TMP/block.sh")"
[ "$!" = "$pid" ] || wait "$!"
kill "$pid" 2>/dev/null
wait'
}

t_case "amd: the sampler runs without nvidia-smi"
if block_run GS_GPU_VENDOR=amd; then
  assert_rc 0 "the block runs"
  assert_empty "$T_STDERR" "nothing on stderr"
  assert_match "$AMD_LINE_RE" "$T_STDOUT" "one AMD LIVE-DIAG line"
fi

t_case "amd: GS_LIVE_DIAG=0 still mutes it"
if block_run GS_GPU_VENDOR=amd GS_LIVE_DIAG=0; then
  assert_rc 0 "the block runs"
  assert_empty "$T_STDOUT" "no LIVE-DIAG line"
fi

t_case "amd: nvidia-smi on PATH is never run"
t_stub nvidia-smi 'echo "45, 1234, 1800, 60"'
if block_run GS_GPU_VENDOR=amd; then
  assert_match "$AMD_LINE_RE" "$T_STDOUT" "the sampler text, not the nvidia-smi CSV"
  assert_empty "$(t_calls nvidia-smi)" "no nvidia-smi call"
fi

t_case "unset vendor: nvidia-smi still feeds the line"
t_stub nvidia-smi 'echo "45, 1234, 1800, 60"'
if block_run; then
  assert_rc 0 "the block runs"
  assert_empty "$T_STDERR" "nothing on stderr"
  assert_match '^  LIVE-DIAG 8f14e45f: gpu\(util,vramMiB,clkMHz,tempC\)=45,1234,1800,60 \| cs2cpu=([0-9]+|\?)% capcpu=([0-9]+|\?)% \(composite=1\) \| audio srcout=\?ms sinkin=\?ms$' \
    "$T_STDOUT" "one NVIDIA LIVE-DIAG line"
  assert_eq '--query-gpu=utilization.gpu\,memory.used\,clocks.gr\,temperature.gpu --format=csv\,noheader\,nounits' \
    "$(t_calls nvidia-smi)" "the nvidia-smi query"
fi

t_case "unset vendor: no nvidia-smi, no line"
if block_run; then
  assert_rc 0 "the block runs"
  assert_empty "$T_STDOUT" "no LIVE-DIAG line"
fi
t_done
