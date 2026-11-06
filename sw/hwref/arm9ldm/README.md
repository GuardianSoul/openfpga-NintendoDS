# ARM9 uncached LDM v1 (standalone, source-staged)

This bounded extension reuses retained memtime2 objects: its original
post-index LDM8, `mt_time`, MPU wrappers and Calico/stock ARM7 runtime. It
is deliberately absent from `PROGS`, the chained runner and the staged
three-probe batch. No deployment follows from building it.

The ready ROM, original objects, exact serial build/check driver and
software-only qualification are in the capsule linked from
[the measurement note](../../../docs/arm9ldm-v1.md). The driver expects a
private `sdk/` copy of devkitARM, Calico, libnds and ndstool plus the existing
qualified Census22 CLI. A coordinator-allocated worker is required to build
or simulate; checking saved CSV files needs no simulation.

`kernels.S` supplies ARM code blobs copied to memtime's existing 1 KiB
ITCM data buffer. `main.c` times 16 blocks per loop at 16/64 loops. The
anchor calls the original retained kernel in place. Signatures execute an
untimed copy with the exact timed prefix and a register snapshot substituted
for its epilogue. No snapshot or output work lies between timer reads.

One block is one LDM for `ldm*`/`fixed*`, two LDM4 for `split4`, four LDM2
for `split2`, eight LDR for `scalar8`, or LDM8 plus four instructions for
`gap4`/`dep4`. Thus the common 256/1024 block counts do **not** imply equal
instruction counts. Four offsets are 0/4/8/12 bytes. Fixed controls read
`main+512+offset` repeatedly, avoiding the original initializer's zero word.
Other loads advance within each 16-block iteration and reset on the next.
`nop16` supplies one no-load, offset-zero loop calibration.

The data-mutant image changes word127 only. The immutable pattern oracle
must reject its final loaded registers. Neither image specifies a DS timing
target or resolves permission/abort, contention or interrupt frontiers.
