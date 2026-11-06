# Shared register byte MLABs and accepted VWR reuse

Production `2df69605` starts at compact `249157de`. Root's selected
`f13a8429` joins E3 and explicitly enables SYS/VWR. Root full-APF codegen,
flag/default/disconnect AST checks and qlint pass. No independent fit or
VWR model was run by this owner. Main reference is unchanged.

Actual1225 vs1223, full-chipds/14.92ns, seed1asR:

| Component | Before→after ALM | M10K | DSP | Disposition |
| --- | ---: | ---: | ---: | --- |
|SYS u_regs|4.0→84.9|2→0|0→0|Priced +80.9ALM RAM reinvestment; fullSYS/actualfault gates below|
|VWR|45.3→128.9|2→0|0→0|Priced +83.6ALM RAM reinvestment; accepted before/equivalence/actualmutant reused|
|wfifo|30.1→30.0|2→2|0→0|M10K retained; tiny packing delta is no saving|
|Whole E3+SYS+VWR batch|24,746.5→24,844|347→343|61→61|CapacityFAIL/noSTA; whole+97.5ALM includes E3/packing, not isolated unit deltas|

LABs unavailable, timing FAIL (STA not reached), seed1asR — Codex.
Root provisionally keeps both trades pending independent proof replay.
No67MHz, canonical-import, DS accuracy/speed, game or card acceptance follows.
`price1225.json` inside the capsule retains exact selected rows, original
receipts and raw-report hashes; no duplicate fit was queued.

Only incoming write data is specialized to32bits: the real caller already
supplies identical32-bit halves and selects one lane's byte mask. All32×64
stored bits, eight byte enables and the full64-bit read remain. Each byte
has a legal32×8native MLAB. A write is physically deposited at the next SYS
edge; registered byte-wise prior-write forwarding masks every native
collision, while the current edge's write remains invisible to that read.
Pending and forwarding payloads are32bits, reused for each half's matching
byte position. No reset, initialization, discard-valid mechanism, new clock,
extra consumer stage or timing exception is added. The general RAM is
byte-identical; inverse removal of the helper/wiring/parameter recovers the
exact old system control/arbitration/readback body.

The accepted `gpu2d_mlab_be_od`/DMA forward pattern is adapted. Previous
actual1223 storage is2M10K/4ownedALM/2,048bits. Unmeasured+120–210ALM planning
was superseded by the actual+80.9 result. An old pumped alternative failed
#1050/#1051 by1.1–1.8ns; it is not revived. CPU and DMA consume the same
SYS registered word and original grant/response cycles. In particular DMA
still reads SAD+DAD or CNT+FILL together; no half-width bandwidth assumption
or row/bit-capacity reduction is made.

Portable, native-QIS poisoned-collision and actual Quartus25.1 vendor checks
pass12,386cycles,10,234writes,4,837collisions and98,704byte comparisons.
All32rows are independently initialized through low/high writes with
different payloads, followed by all256masks across every row and adversarial
collisions. No state is invented for unspecified/unwritten startup bits.
The physical import captures all32×64before words, poisons the target,
deposits and compares the first ordinary read of every row without a settling
edge. Native JSON confirms exactly eight32×8MLAB IP instances. The vendor
SDK's default byte-size warnings are retained; all eight bits of every byte
are tested. Standard mapping/STA remains governed by Root's actual reports.

The complete real `nds_sys` before/new pair, FAST1 with other unit options
unchanged, passes **1,783,282cycles /4,653,087checks in each portable and
native-QIS model**. It compares public outputs and DMA control state through
the original CPU/timer/IRQ/IPC/DIV/SQRT/DMA functional workload. Coverage:
111,367register reads,31,191writes,1,884DMAloads,19CPU arbitration stalls,
159same-address collisions and one complete physical import followed by
public CPU use and ordinary DMA operation. These golden checks supplement
before-version equivalence; they are not new DS measurement authority.

A separate5,081-cycle native extension establishes the stronger restored
consumer gate without repeating the full suite: CPU immediately reads restored
SAD, then only CNT is enabled, and DMA consumes the restored SAD+DAD without
rewriting those fields. It passes10,162checks,688reads,12writes,4DMAloads,
19arbitration stalls,2collisions and one full import. Warm reset retains
physical state; no post-restore tick is inserted. The test-only SDK-bound
physical deposit is not a promoted host canonical import ABI.

Two actual mutations reach public mismatches with private-state-only exits
disabled: rotating the native write byte lane first fails at cycle188068;
flipping the CPU write-owner bank first fails at cycle187983. Both altered
RTL files and their original unchanged verification are retained.

VWR is **mechanical reuse**, not new implementation/qualification. The current
FIFO source is byte-identical to accepted05a971; removing only its STYLE
parameter/attribute yields the exact249source. Onlyx_vwr opts into MLAB,
with its unchanged56-bit interface and64-word capacity. `wfifo` explicitly
stays M10K, preserving1141's negative control. Reused evidence includes four
50kWclock profiles, data/order/credits/reset/wrap checks and the actual output
bit0mutant, plus actual1142's130.9ALM/0M10K mapping. No accepted VWR model or
mutation is rerun; offline hashes/source comparisons merely replay receipts.
The startup/full/drop/clock/publication contracts remain the accepted ones.

`evidence.tar.gz` and `verify.py` provide229hash-bound members, including all
stage inputs/commands/PIDs/reaped receipts, exact production source, VWR
accepted packet, actual mutants and current price rows. Vendor SDK source is
externally hash-bound and not redistributed.

On an allocated L1 slot, `prepare.py` makes the thin bundle. Run main's
absolute `tools/laptop-run.sh` on
`/home/user/Git/NDS_Pocket/build/sys-regs-mlab-l1` with
`env REG_TEST_MODE=helper|vendor|caller|wrongbyte|owner|extra|shape python3 worker.py`.
Preserve each fetched receipt before the next mode replaces it. One worker,
NI10/jobs1/threads1,150MiB scratch cap,1GiB free floor,240s stage cap. All
owned children are reaped and objects pruned. No extra baseline or standalone
fit is required to review the saved packet.
