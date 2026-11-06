# Unmeasured capture-source rounding probe

`make -C sw/hwref/capsrc` builds the standalone new-only
`build/capsrc-v1/capsrc.nds`, writing only to `/hwref/capsrc-v1/`.
It leaves the historical menu unchanged. This stages the DS31 S4 follow-up;
no device run has been made.

The64 resumable segments cover signed DC1/3/255/257 and their negatives at
volume127/div0,64/div0 and65/div2 on capture source channel0 and channel2.
Pan alternates0/127. The last16 segments feed the same source to channel0/2
and pair capture0's8-bit format with capture1's16-bit format. All256-sample
buffers occupy whole32-byte cache lines. Polling is bounded and both channels
stop before source data changes. No expected rounding or startup phase is baked
into the probe. It records all raw samples, including startup transients.

Results use capsrc_index.csv, capsrc_info.txt, capsrc_progress.txt and
capsrc_<segment>_L/R.bin; prior sndq results are preserved. The64-case count fits
the64-entry resume table. The source is adapted from sndq v3's measured procedure.
The SDK-linked NDS image completes all64 segments in qualified Census22;
the actual source register state, source RAM fetches and capture writes are
checked against all128 saved buffers. Seven actual-artifact mutations are
caught. See [batch qualification](../../../docs/hwref-batch22-20261101.md).
Both completed-prefix and interrupted-segment restart sandboxes are qualified;
the latter correctly remains incomplete when its interrupted case is skipped.
See the [follow-up](../../../docs/hg-live-gp3d193.md). Real-hardware results remain pending.
