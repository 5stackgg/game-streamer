Set `VKCAP_PIPELINE_DIAG=1` for a temporary capture Job to log metadata at each
available stage every five seconds. It is off by default and does not change
queues, encoders, caps, timestamps or frame content.

`FLOW-DIAG` reports the actual buffer rate and negotiated size/rate at capture,
HUD/X11, compositor, GPU conversion, encoder, parser and SRT sink boundaries.
Compare neighboring stages to find the first throughput drop. The SRT counter
counts MPEG-TS buffers, so compare its bytes/s and timestamp lag rather than
treating its buffer rate as video FPS. Encoder output may be batched or split;
use the parser's negotiated alignment and a receiver's frame count to confirm.
`pts_lag_ms` converts the last buffer's PTS through that pad's segment before
comparing it with the pipeline clock. It is -1 when unavailable.

Backpressure can also reduce upstream rates. A throughput gap narrows the
investigation; it does not measure which element spends the CPU or GPU time.
Compare rate changes, growing lag and receiver measurements together.

A consumer's present counter alone does not prove the viewer receives that
frame rate. A 60 FPS capture with 5 FPS after conversion/encoding needs a
different fix from a receiver that gets 60 FPS and displays 5 FPS. Keep a normal
receiver measurement alongside these logs. No frame pixels, destinations,
credentials or codec extradata are logged by these counters.

Run the CPU regression with GStreamer development headers and base/bad/ugly
plugins installed:

```sh
gcc -O2 -Wall -Wextra -Werror -o /tmp/flow-diag-test src/vkcapture/flow-diag.test.c $(pkg-config --cflags --libs gstreamer-1.0)
/tmp/flow-diag-test
```

It creates a real synthetic 60 FPS input and a deliberately slow 5 FPS encoder
path, checks where the drop occurs, checks buffer-list accounting, and verifies
that enabling diagnostics preserves all 60 frames of a finite encode. It does
not qualify a GPU or replace a normal live-stream test.
