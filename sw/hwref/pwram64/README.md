# Private WRAM placement probe v1

This standalone, new-only probe supplies a software-qualified measurement
producer for the proposed external placement of ARM7's private 64 KiB. It
changes no core RTL, historical menu, card preparation or accepted DS scope.
Census qualifies its execution and outputs; its elapsed times are not DS
measurements or permission for an external-memory wait.

The retained sources cannot decide this question: run30 warms a fixed data
word/four words, run38 toggles a fixed word during sound, and run39 traverses
instructions in a 2 KiB footprint. None measures a 64 KiB dependent-data
footprint or a burst of more than eight distinct-line stores. Their accepted
results remain controls within their recorded bounds.

## Layout and cases

ARM7 code, SDK state and a reserved 4 KiB temporary stack occupy shared WRAM
at `037f8000..03800000`. The original private startup/IRQ/BIOS addresses stay
unchanged. A wrapper saves SP/CPSR, masks IRQ/FIQ, switches stacks, backs up
**all** `03800000..03810000` into MAIN, executes the test, restores and compares
every private byte, and only then restores SP/CPSR. Failed restoration never
returns onto the saved stack. MAIN also holds result, graph construction and
DMA destination buffers; graph tables are not read by timed kernels.

There are 13 independent journal groups, five repetitions each:

| Groups | Access pattern | Three raw windows per repetition |
| --- | --- | --- |
| 0–5 | One pointer at byte28 of each32 B line; 1/8/64/256/1024/2048 nodes (32 B through64 KiB footprint) | 1 load; one full cycle; four full cycles |
| 6 | 16384 stores to one fixed word | CPU issue; ordered CPU readback; whole-private DMA readback |
| 7–12 | 8/9/16/256/2048/16384 distinct words | CPU issue; ordered CPU readback; whole-private DMA readback |

Each read window starts with the **same** complete guard initialization,
seeded Fisher–Yates pointer-cycle installation and ascending bytewise FNV scan
of all 64 KiB. The cycle uses seed`6d2b79f5`, LCG`1664525*x+1013904223` modulo2^32,
and descending Fisher–Yates swaps. Every timed next address comes from the
preceding load. The one-node case is a fixed-word control. This exact
prehistory is part of the contract; no cache-invalidate operation or claim
that every access must be cold is implied. Compare absolute windows before
using the paired lengths; no bookkeeping subtraction is supplied.

Distinct stores visit byte offsets `(j % 2048)*32 + (j / 2048)*4`, so the
first16 touch16 different lines and the full case touches every word. The
8/9-word tail and16-word body issue consecutive STRs; the long body advances
one 512 B block between bursts. The fixed-word control uses16 consecutive STRs
per iteration. Values are`12341234`; every untouched word remains its exact
guard value. Ordered CPU reads follow the same address order. DMA7 channel3
then copies all 64 KiB to MAIN, with every word checked against an independent
expected image. The full-store case additionally captures64 PCM16 samples
from channel0 reading private WRAM; samples 8..63 must equal`1234`.

## Endpoints and evidence limits

TM0/F1 plus cascaded TM1 provides raw32-bit ticks at33.513982 MHz, resolution
one timer tick. Every window retains both absolute timer samples, unsigned
difference, VCOUNT endpoints, operation count, checksum and terminal pointer.
The linked shared-WRAM timer/call wrapper is included in the interval; it
performs no MAIN data access between timestamp samples. The DMA interval
includes programming source/destination/control and polling completion.

The store endpoint means CPU issue/return, CPU readback means CPU-visible
coherence, and DMA readback means DMA-visible coherence after the intervening
CPU reads. These are separate windows with retained absolute endpoints and
real gaps. None identifies physical backing-store drain. The sound suffix
checks visibility **after** writes/readback/DMA; it does not close concurrent
same/different-block instruction/data/sound deadlines. Existing run38 remains
scoped evidence for those recorded fixed-word cases. A candidate still needs
its own admission/return/credit/forwarding/commit contract and combined-client
qualification. No area saving or external-placement feasibility is claimed.

Each68,928-byte group contains32 header words, two16-word contexts,
15raw64-byte samples, before/after1024-byte kernel areas, a64-sample sound
capture and the complete65,536-byte DMA image. Restore hashes and a full
memcmp verdict are retained; context records shared SP, masked CPSR, IRQ,
WRAM ownership, timer, sound and power state. ARM9 saves MPU/cache setup and
the live ITCM image. Its GO/wait helper runs IRQ-masked from ITCM and polls
only I/O while ARM7 works.

## Build, replay and continuation

```sh
make -j1 -C sw/hwref/pwram64
python3 sw/hwref/pwram64/seal.py build/pwram64-v1 build/pwram64-v1/layout.json
python3 sw/hwref/pwram64/check.py PATH_TO_RESULT_DIRECTORY build/pwram64-v1/layout.json --csv raw-windows.csv
```

For qualification, put the frozen`pwram64.nds`, `layout.json`, `check.py` and
`qualify.py` in a small dedicated staging directory. Use main's absolute
`tools/laptop-run.sh` to run `python3 qualify.py`; the default bound is1200
frames, one child/thread at a time under the helper's nice10. Do not mirror a
large unrelated worktree. The checker requires only Python's standard library.

The probe directory is `fat:/hwref/pwram64-v1`. A source-build binding rejects
mixed producers before writing output. Strict START/DONE order and exact
saved-result validation allow completed groups to resume without rewriting
raw data. An interrupted START remains incomplete; later independent groups
can run. A damaged DONE is refused. The qualification runner tests a fresh
capture, unchanged resume, interrupted START, damaged DONE, wrong producer
and an actual STR-to-NOP change in the frozen NDS payload. `--resume-run`
continues only missing software gates after verifying retained output hashes.

The SDK/linker/handshake/journal structure adapts the existing `a7mulmix`
producer; whole-private testing needs the new shared-stack wrapper because
that producer and `wramarb` execute from private WRAM. No on-chip replacement
or new area implementation is introduced. See
[the retained qualification](../../../docs/results/pwram64-sdk-20261103/README.md).
