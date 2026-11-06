# DS41 exact-code native gate

Simulation-only adapter for the actual DS41 four-case/64-record return.
No physical-card image, new hardware request or production timing change.
`prepare.py` pins/extracts the archived59-member evidence, verifies every
payload hash, retains all64 original register/timer/CPSR records, all eight
CP15 snapshots and generates the312 exact captured ARM instruction words.
Preparation never invokes a compiler or simulator. The private Makefile
requires an explicit worker-lease token before any compilation target.

Prepare with `python3 tools/scorecard/ds41/prepare.py --out <fresh-absolute-dir>`.
After machine allocation, run the private Makefile with NI10, jobs1,
threads1, `HWREF_BUILD_LEASE=<allocation>` and the existing repository ROOT.
The coordinator's worker ownership/capacity checker remains authoritative;
the Makefile token alone does not allocate a machine.

Code executes at captured01ff8020, context at02ff0000, timer04000108 at F/1,
reload0. CP15 restores the exact captured sixteen fields, including MAIN
cacheable/writeback and the effective I/O C0B0 region. Original code is
copied before each case; the measured leaf, prologue64 settle operations
and output/restore epilogue are not recompiled or patched. Every trial
checks live code bytes before/after, then retains the four timer values,
actual readable register state and CPSR. Four full live code snapshots and
all64 per-trial byte/FNV checks enter the result, with case CP15 before/after.

The caller/stack02ff3e00 and idle ARM7 replace Calico. DS stack, full
subdisplay/background and pipeline state were not captured. The saved
CPSR precedes original memset/call; it is a controlled seed, not proof of
DS leaf-entry NZCV. Only recorded mode/IRQ and supported observable context
are asserted. Absolute timer counts and saved current-count differences
remain visible, not normalized or used as a timing allowance. Measured
intervals must match4SYS read/read and5SYS read/stop for **all64** records.
No generic wait, opcode substitution or fitted phase shift is accepted.

The6976-byte result is built in DTCM02ff0100 and copied after timing to
MAIN023d0000. Because captured MAIN is writeback-cacheable, output lines
and the canonical result line are explicitly cleaned/drained only after
all measurements/snapshots, before adapter_done. Native export reads the
physical PSRAM result. Three functional canonical values are64 rows,
4 cases and0 errors; timing is a separate exact-vector gate.

`check.py --prepared <dir> --main <full-MAIN.bin> --out <report.json>`
checks all actual inputs/code/context and reports all64 native/DS raw pairs.
Add `--require-ds` for native timing acceptance. The software/Census control
checks integrity without adopting emulator timing as DS truth.
`ADAPTER_CODE_MUTANT` actually executes a neutral ADD r0,r0,#0 in place of
a captured settle MOVr8,r8 after the before-byte check; it is a host-only
negative control and never the native positive image.

`witness.svh` is included in the private native testbench only. It reads
actual CPU/MEM, fabric grant/ACK, I/O descriptor, timer sample/write and
post-edge counter/control signals. It drives only its local counters/file
and has a50000-record watchdog. CPU presentation, MEM ready and merged retire
diagnostics are separate events, so a replay/posted completion cannot be
silently relabelled as a peripheral sample/commit. Every source-specific
sample/commit event is retained with clock-domain counter and simulation
time. No chronological order is inferred from file order at simultaneous
clock edges. `check_witness.py` joins the actual descriptor order with the
five captured leaf PCs per row and ties four sampled values and the stop
commit to the exported architectural counts. It does not infer a DS
pipeline stage or force DUT state.

A native run must independently pass declared source/profile/physical,
video and model guards, actual MAIN result/input checks, passive witness
coverage and the full64-row timing vector. The merged ARM9/ARM7 debug mux gives
only272/320 leaf retire records in the first actual run; it prioritizes ARM7.
Those records are diagnostic, not a lossless retirement timeline. All320
CPU access PCs and576 physical descriptor/sample/commit paths are required. The new witness changes the
harness fingerprint; a cached published273 model cannot be reused as though
it contains the witness. The current job uses immutable production27340ba4,
its qualified f149 harness/37-field profile and a separately hashed passive
include; the original source/results/model are untouched.
