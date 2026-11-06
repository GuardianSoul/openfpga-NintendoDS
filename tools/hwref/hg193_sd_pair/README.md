# HG193 profile58 SD-pair source adapter

This is an opt-in simulation publication adapter for the existing HG193
eleven-image payload, bound to the actual 2f86/profile58 extended-host build.
It does not edit production RTL, the default launcher or the default testbench.
The historical HGSS title-screen stretched-triangle issue remains closed.

Status: **scoped component qualified; whole-model composition pending**.
Full actual frozen-profile elaboration, isolated GPU publication/readback,
compiled wrong-record/tag controls and the component default-before control
pass. Results are in `docs/results/hg193-sd-pair-component-20261102/`.
This does not qualify a combined CPU/cache/transport hook or an HG scene.

Prepare from this checkout:

```sh
python3 tools/hwref/hg193_sd_pair/prepare.py --out build/hg193-sd-pair-source-20261102
python3 tools/hwref/hg193_sd_pair/check_source.py --out build/hg193-sd-pair-source-20261102/source-check.json
```

The host checks read the immutable retained payload and production sources.
They never launch a simulator, compiler, exporter, first-use probe or ROM.
`binding.json` pins the production manifest, compiled-input manifest, build
command, actual compiled TB, eighteen relevant compiled production files,
two existing snapshot/drain helpers and the accepted638 loader/context map.
Paths are recorded from compiled inputs and checked against production hashes;
the adapter does not substitute the moving main checkout or this old unit's RTL.
The fifty-eight explicit profile fields are also emitted as runtime assertions.

## Translation and retained state

The canonical SDRAM image occupies word addresses `0x1a0000..0x1bffff`.
Each old four-word record at key `{bank,index[12:0]}` becomes eight words:
the same four words, `0xc4e00000 | key<<2`, its inverse, `0x47335344`, zero.
This is the bound `nds_g3d_sd_records` layout. Header keys are `0..2047`;
vertex keys are `2048+vertex`, with at most6144 vertices per bank. The payload
retains all16384 keys, including inactive words, rather than inventing contents
for the empty writer bank. No journal record is fabricated.

The retained order/Y tables remain4096 entries in `{bank,slot}` order; both
bucket copies and all2048 links remain unchanged. Writer bank1, render bank0,
622 polygons and4500 native vertex occurrences are retained. `so_count` is622.
The ready flag is published last, after backing records, lists and context;
readback then checks payload words, all packet guards, lists, bank ownership,
generations, context, sort tags and cold raster/ring state while clocks are held.

The accepted3712 context indices expand to4141 old path assignments, including
RF aliases. All eighteen64-word clip mirrors and four64-word finish mirrors
agree with the retained RF image. Translation collapses only those proven
aliases: clip words0..6,8,9 go into both current nine-word banks, and finish
mirrors go into both current TDP copies. The result has2869 target assignments.
RF stacks, FF attributes/texture matrices, PU continuation, LOAD4x4 projection
identity, four shininess tables, light colors/products/material caches/vector
matrix, and front/timing context retain their accepted logical values.

Two omissions are explicit: legacy `fin.sg[4:5][0:15]` (32 live words) and
`fin.ent[0:3][0:15]` (64 frozen words) were never exported in the3712-word image.
The adapter reads and preserves all96 current live words and64 independent
frozen words using the bound snapshot helper, replacing only live slots0..3
with the64 retained HG words. It does not guess the omitted contents.

The narrow source argument is in the bound `gpu3d_gxeng.g_pu`: HG has `pm=1`,
`vn=0`, `cs=0`, `lr=0`, no partially submitted polygon and an empty writer.
`pk_la[0:1]` select reuse slots4/5 only when `cs` is true. A later strip's
reuse is populated by the ordinary COPYV path before it becomes eligible.
The bound finish unit is idle, so its old frozen entries have no active reader;
each next `hgo` captures fresh slot/version selectors. Unsupported continuation
is rejected. The missing values therefore remain **unavailable but inactive**,
not claimed to be captured HG state. Component qualification confirms all
32+64 omitted words remain unchanged using distinct nonzero, mixed-version
snapshot inputs. The combined hook remains a coordinator composition obligation.

The canonical payload carries no generation. Caches are invalidated only at
the held/drained boundary, and prior-bank cache identity is rebased to the
actual empty journal head. Tail/copied/sent/safe/head, publication counters,
transport state and pending physical work are never forced complete. The
adapter restores only journal writer-bank/vptr ownership and the published
render-bank identity. Future journal generations proceed from the actual
drained cursor. Replacement ranks and inactive cache payloads are retained.

Cold raster line buffers and local ring storage are zero and unpublished,
as in the accepted638 loader. Ring publication counters are zero; there is
no valid predecessor frame and no reference pixel deposit. Retained prior-bank
render latches/tables are separate from current IO registers, whose ordinary
replay is checked rather than bypassed. Frame85/release7/raw11/ref5 remain the
coordinator's unchanged whole-model mapping; this adapter changes no schedule.

## Composition contract

The generated include is intended inside the actual frozen `tb_ds_pocket`,
after `sd_poke32`/`sd_peek32`. It is guarded by `HG193_SD_PAIR_OPT_IN`, has no
initial block, and has no caller in the existing default build. A coordinator
overlay must explicitly include it and call:

```systemverilog
hg193_publish(prepared_directory, actual_all_clocks_held, actual_system_drained);
```

The coordinator must bind both arguments to the real publication hook, with
all relevant clocks held across the entire zero-time task/readback. A low
clock level alone is not proof of a stopped clock. The task additionally
checks actual SYS/FAST levels and line193/pre-release boundary, the existing
SD-pair drain predicate, geometry/frontend/FAST owners, completed cache clear,
idle caches and queues, raster/ring/texture/physical transfers, empty writer
sort tables and ordinary replayed render registers. It rejects rather than
drains or advances any live owner. Snapshot/drain helper task names are
prefixed in the prepared package to avoid colliding with generic import tasks.

Before compiling or executing a composed model, validate every generated
file against `preparation.json` and revalidate `binding.json`. The SV loader
checks descriptor, continuation and translated packet consistency; it does
not implement file SHA256 itself. Do not merely add seed flags to74f, remove
the existing launcher's seed refusal, bypass legacy SD-pair fatal gates, or
call the generic2632-word MKDS context helper with HG data.

## Qualification boundary

Host/source equivalence checks cover all65536 retained record words, all3712
context indices, all4141 accepted assignments/aliases and all2869 target paths.
Byte identity covers all eleven original images. Deliberate clip-replica,
finish-replica, live-slot, strip-reuse and partial-polygon mutations are
rejected. Independent packet decoding covers both banks and all format/tag
fields; wrong record/bank/tag/inverse/format/tail host mutations are rejected.
These are host checks, not evidence that an RTL guard executed.

`tb_record_guards.sv` provides a bounded component test against the **actual
bound canonical RTL**: five real reads (header0/header621/vertex0/vertex4499/
writer-bank empty record), wrong-record replacement and wrong-tag mutation.
Negative runs must terminate at production
`SD_RECORD_STALE_OR_CORRUPT_RETURN`, without `p_rdone`; a timeout or a testbench
assertion is not an accepted rejection. Five valid reads pass; both mutations
terminate at that actual production guard without publication.

The L1 NI10/j1/t1 component chain elaborates the full actual frozen hierarchy
and extracts all60 resolved GPU parameters for the isolated publication fixture.
It proves held/drained acceptance, held/owner/strip rejection, preserved32+64
inactive snapshot words, full readback and sort/cursor preservation. Separately
compiled adapter-absent and enabled-but-not-called components have identical
default-before fingerprints (`611edf3c4c3e1de0`) over the2869 mapped paths plus
banked tables, ring storage, physical snapshots and ownership. The fixture waits
for real engine idle after reset, uses ordinary GPU IO replay, and explicitly
supplies the accepted empty-writer sort epoch as an input fixture. It does not
run the whole shell's ordinary state importer or replace its full-system drain.

Actual full elaboration found and fixed the source draft's four old transport
owner paths. The adapter now checks `g_sparb.u_arb` owners, selected clients,
beat counters and requests. Production RTL and default features remain unchanged.
All component children were reaped and private compiler scratch was removed.
Full HG/native runs require coordinator composition and remain outside this action.
