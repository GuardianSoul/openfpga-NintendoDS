# ARM9 local progress during DMA

This transfers the live-progress test from the earlier nds-pocket work.
Upstream already permits local execution during DMA (`DMA9_RUN=1`); this
regression protects that behavior without changing the CPU or DMA RTL.

The ARM9 copies a position-independent function and its literal pool to ITCM
at `0x1000`. With the common CRT's caches off and stack in DTCM, it starts a
1024-word main-RAM DMA3 copy and increments R10 from `0xD1000000` through
`0xD1001000` using only local instructions/registers. External DMA polling
happens after the increment loop. ARM7 runs a branch-only idle loop so its
register writes cannot hide ARM9 writes on the shared debug port.

The ROM checks the final counter, every destination word, and an order-sensitive
checksum. These eventual checks should also pass when ARM9 is held throughout
DMA; they alone do **not** demonstrate overlap. The simulation option
`--dma-local-check` additionally observes consecutive marked ARM9 R10 writes
in the copied ITCM range. It requires all 4096 increments and at least eight
with DMA busy at both adjacent CPU-edge samples. It also discards the first
16 marked writes of each uninterrupted busy episode. Holding fetch permits
previously accepted work to retire: the tested SOLO_ONLY/IB4 frontend holds
at most four tokens (`ib4_n + p_v + f2_v`), plus five backend slots
(E1/E2/E3/WB/WB2). These ADD/SUBS/BNE instructions each use one uop. Sixteen
excluded writes exceed that nine-token bound without assuming a drain time.
Raw in-DMA writes are reported separately; one raw write in a held build
must not be mistaken for proof that the core fetched more local work.
It implies `--result` and requires a fresh boot. Save-state restore is excluded.

Run `make test-dma-local TOOLS=/path/to/tools BOOT_ROMDIR=/path/to/bios`, with
Clang/LLD/llvm-objcopy available as for `make ds-tests`. Or invoke
`python3 tools/ds/check_dma_local.py --tools /path/to/tools --bios /path/to/bios`.
The driver runs the actual Pocket parameter set (including `clk_2x`), then a
separate `DMA9_RUN=0` build. Each gets a normal WRAM-ARM7 case and a delayed,
jittered main-RAM-ARM7 case. The negative must preserve **all three** ROM checks
but lose **all** live increments; a data failure, timeout, or generic crash does
not qualify as a successful negative control. Logs, exact commands, input
hashes, and a machine-readable verdict go under `build/dma-local-check`.

Scope: ITCM, CPU_FAST=0, bounded simulation cases. No claim about cache-hit
execution, an external transaction accepted before DMA, physical concurrency,
performance improvement, or complete game compatibility. A native DS/Pocket
run can check the final values; the live criterion needs an instrumented
observer and cannot be inferred from a passing display.
