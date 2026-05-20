#!/usr/bin/env bash
# Synthesize motion/public/outro-audio.wav from ffmpeg lavfi sources.
# Single ffmpeg invocation: four layers (drone pad, rising swell, sub
# impact + click, high shimmer) mixed with adelay offsets to land the
# impact at the same beat the Outro composition flashes the logo.
#
# Re-run after editing the timing constants below; the wav is committed
# to public/ so Remotion picks it up via staticFile("outro-audio.wav").
# In Docker we re-run this at build time so the layer chain stays in
# sync with whatever motion/ has in the image.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(cd "$HERE/.." && pwd)/public/outro-audio.wav"

# Match Outro.tsx total duration. If you change one, change the other.
TOTAL_S=3

# Land of the impact (when the blade lines meet + logo flashes). Keep
# in sync with the FLASH_S constant in Outro.tsx.
IMPACT_S=0.5

# Helper: adelay takes ms.
swell_delay_ms=0
sub_delay_ms=$(awk -v t="$IMPACT_S" 'BEGIN{printf "%d", t*1000}')
click_delay_ms=$(awk -v t="$IMPACT_S" 'BEGIN{printf "%d", (t-0.02)*1000}')
shimmer_delay_ms=$(awk -v t="$IMPACT_S" 'BEGIN{printf "%d", (t+0.2)*1000}')

mkdir -p "$(dirname "$OUT")"

# Layered design (frequencies chosen so the pad doesn't fight the
# impact and the shimmer sits well above the body):
#   pad     —  C2 + G2 + C3 sine, fades in, holds, fades out
#   swell   —  pink noise bandpassed (200–4kHz), 0.8s ramp
#   sub     —  55Hz sine, 0.3s exponential decay
#   click   —  brown noise burst, 0.15s
#   shimmer —  1760Hz + 2640Hz bell, fades in/out over 2.5s
#
# We synthesize each layer in its own input then mix them once at the
# end. adelay places sub/click/shimmer at IMPACT_S so the visual
# flash lands on the same beat. alimiter at the end keeps peaks from
# clipping when the mix sums hot.

ffmpeg -y -hide_banner -loglevel warning \
  -f lavfi -t "$TOTAL_S" -i "sine=f=65.4:r=48000" \
  -f lavfi -t "$TOTAL_S" -i "sine=f=98:r=48000" \
  -f lavfi -t "$TOTAL_S" -i "sine=f=130.8:r=48000" \
  -f lavfi -t 0.8         -i "anoisesrc=c=pink:a=1:r=48000:d=0.8" \
  -f lavfi -t 0.3         -i "sine=f=55:r=48000:d=0.3" \
  -f lavfi -t 0.15        -i "anoisesrc=c=brown:a=1:r=48000:d=0.15" \
  -filter_complex "
    [0:a][1:a][2:a]amix=inputs=3:weights='1 0.7 0.5':normalize=0[pad_raw];
    [pad_raw]lowpass=f=400,volume=0.16,afade=t=in:d=0.6,afade=t=out:st=1.8:d=0.9[pad];

    [3:a]highpass=f=200,lowpass=f=4500,afade=t=in:d=0.3,afade=t=out:st=0.6:d=0.2,volume=0.45,adelay=${swell_delay_ms}|${swell_delay_ms}[swell];

    [4:a]afade=t=out:st=0:d=0.3,volume=0.9,adelay=${sub_delay_ms}|${sub_delay_ms}[sub];

    [5:a]highpass=f=180,lowpass=f=3500,afade=t=out:st=0:d=0.15,volume=0.55,adelay=${click_delay_ms}|${click_delay_ms}[click];

    [pad][swell][sub][click]amix=inputs=4:duration=first:normalize=0[mix_raw];
    [mix_raw]afade=t=out:st=2.55:d=0.45,alimiter=limit=0.95:level=disabled,aresample=48000[out]
  " \
  -map "[out]" \
  -ar 48000 -ac 2 -c:a pcm_s16le \
  "$OUT"

echo "build-audio: wrote $OUT ($(du -h "$OUT" | awk '{print $1}'))"
