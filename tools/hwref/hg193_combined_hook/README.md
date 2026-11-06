# Shared import source overlay, aeaa0cb3 / ROM65

**Targeted WRAM runtime proof passes; combined HG history remains unqualified.**
The single observed native60 game model passed24576 real-memory readbacks and
all four actual wrong/missing controls, then rejected HG publication at the
fixed CPU/cache drain boundary. See
`docs/results/shared-import-observed60-runtime-20261102/`. Full scene proof
and the individual failing CPU predicate remain unknown.

The next source-only full-game capture composition is prepared by
`prepare_capture.py` and checked by `check_capture.py`. It classifies all26
clauses, retains strict guards, adds passive clause/address diagnostics and
reuses qualified scenes63 capture helpers with106 observation frames. See
`docs/results/shared-import-capture60-source-20261102/`. Preparation authorizes
no compiler/model execution.

The preparation/check tools
never run a compiler or model. The separately invoked `build_game.py` executes
one coordinator-authorized build behind recorded controller/child PID gates.
Runtime equality is unknown until the next shared candidate is qualified.
Normal testbench/launcher defaults and production RTL are untouched.

```sh
python3 tools/hwref/hg193_combined_hook/prepare.py --out build/shared-import-aeaa-20261102
python3 tools/hwref/hg193_combined_hook/check_source.py --base build/shared-import-aeaa-20261102
```

The generator reads exact git blobs from
`aeaa0cb386d2fbd6f8d2505f8033015956da54b5`. It does not follow moving main.
The manifest records the explicit change from c445c240 and the differences
from the prior2f86/74e00e97 component control. Accepted ROM65 is source-bound
with its caller ports and phase state; old qualification is never relabeled.

## Immediate contract: all-scene internal WRAM

The original TB loads `imp_sram` into external SRAM. With `A7_WRAM=1`, the
current `arm7_wram` backend instead uses two internal memories. The stateload
tables do not copy them. The accepted638 TB's direct deposit is ported into
the private overlay, independently of HG history, immediately after ordinary
external-memory loading and before waiting for the two ready words.

`COMBINED_STATE_IMPORT` plus `+combined_wram_restore` and
`+combined_wram_expected=BOUND_SCENE.hex` enables this simulation-only contract.
Without that define/argument, the original actor executes unchanged.

Every one of24576 words is pinned:

| Existing bytes / word indices | Actual current target |
| --- | --- |
| `wram7.bin`65536bytes, LE32 → `imp_sram[0..16383]` | `dut.ds.u_wram.u_private.mem[0..16383]` |
| `swram.bin`32768bytes, LE32 → `imp_sram[16384..24575]` | `dut.ds.u_wram.u_shared.mem[0..8191]` |

`wram-input-contract.json` verifies all147456 words across the existing heavy,
race, corner, startline, AC and HG inputs against the retained Census23 export
bytes and ready hashes. The expected hex files are byte-identical copies of
those existing `imp_sram.hex` inputs; no input is replaced or regenerated.
At runtime the helper first compares all24576 normal input words with the
bound expected image, deposits the two banks and reads every word back.
It refuses a wrong layout, duplicate invocation or unknown fault mode.

The same shared candidate can compile `COMBINED_WRAM_FAULTS` for four actual
target-memory controls: `+combined_wram_fault=wrong-private`, `wrong-shared`,
`missing-private` or `missing-shared`. Wrong controls flip a deposited word;
missing controls poison a fixture word then deliberately omit that bank's
deposit, so initial zero equality cannot hide the omission. The real readback
must fail at the corresponding `COMBINED_WRAM_*_READBACK_MISMATCH`. Those
controls are staged, not executed or claimed as RTL proof. Positive and
negative runs belong to the next pinned shared candidate, not a new baseline.

## Separate HG history hook

`HG193_COMBINED_HOOK` plus the existing retained HG seed/kind arguments enables
the separate HG history hook. It also requires successful WRAM readback.
The ordinary import ordering remains: memories/WRAM → both stateload ready
words → accepted6383999 SYS edges plus matching pre-release falling half-cycle
→ history publication → the same original release SYS edge → overlay/block
restore → KEYINPUT release/`imp_stub_pend` →400 SYS clocks. The original stub
bytes return only after the first ARM9 retirement outside the stub. CP15/cache
invalidations and final MOVS stay in stateload's existing tails.

At that fixed boundary the hook aligns to FAST falling within the same SYS
half-cycle, captures ten clock views and holds them at their existing levels.
It advances no time during publication/readback and never waits for readiness,
an extra line or a different frame.212 named predicates cover ARM9 memory/CP15
and cache requests (caches/MPU still off), ARM7 port/return owners, CPU-domain
requests, fabric/read-ahead, WRAM ports, PSRAM request/stream/write groups,
SDRAM descriptor toggles, all return/write FIFO ownership pointers, physical
controller/return tags, capture/cart traffic and the real GPU drain gate.
CPU architecture and valid pipeline contents are not rewritten: CPU clocks
are held and all relevant accepted memory work must be drained.

ROM65 is specifically guarded at the M-captured, pre-E boundary: dictionary
enabled, reset inactive, `ph=0`, `tg=tq`, captured index equal to the selected
PC class and dispatcher at NX_DISP with `ev_q=0`, no MMIO matrix request and
`upc_n=upc`. The source NX_DISP rule therefore keeps the ROM input at held PC
independently of restored RF values; this does not rely on a combinational
delta having settled before the immediate check. Address/index/word/phase/reset are retained
across the context deposit and checked before clocks resume. No ROM phase,
decoder output or pipeline state is reset or fabricated. A mismatch fails at
the original boundary; it is not repaired by delaying release.

The accepted638 history, pm1/vn0/cs0/lr0 restriction, preserved96live/64frozen
snapshot ABI, frame85/release7/raw11/reference5 bounds remain controls. The
current signed-Z arithmetic change and ROM65 require shared-model runtime
qualification. Nothing here reopens HG-WING or accepted WRAM timing.

## Remaining binding and runtime proof

For the supplied observed native60 actor, use `compose_observed.py` with the
explicit TB and host-root paths, then `check_observed.py`. This copies all actual
compiled files and recursively resolved includes, preserving the CPU observers
and public captures. Six guarded edit sites reconstruct the exact donor085
default actor. Its sound-only import selector is extended for the explicit
combined import, and that request suppresses the competing clean-boot clear.
The existing WRAM deposit becomes the default branch of the checked helper;
it cannot mask deliberate missing-deposit faults.

The observed composition replaces the placeholder with all60 actual parameter
checks and exact production/input hashes. The old failed-compiler freeze is
retained as history; its eight CPU observer/reader replacements are explicitly
recorded against the successful e133 release. No donor file is written.
`model-pin.pending.json` remains unusable until the single game build succeeds.
`verify_game_launch.py` then checks the actual ELF hash, build argv, every bound
copy and selected original scene inputs before a launch. It never runs a model.
ROM_AW25 is an explicit game-host capacity change for the existing HG image;
the60 core settings stay unchanged. The frozen native60 kernel run is separate.

The raw-source preparer's generated binding contains an unconditional fatal guard.
The coordinator must supply the exact shared source/profile/compiled inputs,
all generated includes and scene input hashes, then freeze/check the actual
binary hash in its launcher. Do not remove that guard without the binding.
The old58-field assertion file is retained only as a `.txt` control; it is not
used to authorize this new source/profile.

The next shared model must prove actual elaboration, real24576-word readback
for the selected existing scene, wrong/missing controls, full-import/default
ordering, all-system drain at the same HG release edge, clock-force backend
and ROM65 caller/address/phase preservation. Prior six-scene failures and
unknown restored architectural state equality remain explicit. Five source
mutations and exact default-branch reconstruction are host checks only.
