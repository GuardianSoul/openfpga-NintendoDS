# Clip16 debug/import bridge — local proof passed, canonical binding OPEN

Branch starts at d39f2763. All changes are sim/runtime import code or this
new bench/runner; production leaves, services, clocks and constraints are
unchanged. Local proof ran on Root-assigned DesktopD1, NI10/jobs1/threads1. D3 stayed
with Shell. No production or service files changed.

`runtime_import_clip_store.svh` defines preflight/deposit/readback helpers.
Define RUNTIME_CLIP to the clip scope; define RUNTIME_CLIP_STORE_ENABLED at
elaboration only when PUMP_STORE=1. Both branches check the selected profile.
Literal bank bindings map old g_word4..8 / RF offsets4,5,6,8,9 into sf0..4.
They restore160full32bit words, five outside holds and five inside primitive
read registers. QIS primitive backdoor is explicitly unsupported/rejected;
this bridge is for the portable simulation backend, not FPGA savestates.

The only admitted boundary is clean idle/empty/no live write/divider,
both clocks low, certified post-M/E-next, matched epoch/seen and pending_we0.
Missing groups/held reads, unknown payloads, active work or pending writes
are rejected before deposits. No startup ticks/reset/flush or metadata
normalization occurs. Metadata is left EXACTLY unchanged. Old pending
address/data are gated by pending_we0 at E; next E captures inside_addr and
forward metadata before M uses them. The executed first-use bench poisons
those dead fields while preserving phase/empty-pending and supplies every
live O/I. A separate adversarial test poisons held O/I and verifies that
ordinary E/M refresh precedes their first late consumer in this idle fixture.

Existing import_gx_context/verify_gx_context retain their two/one-argument ABI
and their original default behavior. With enabled macro they reject direct
old-mirror-only calls. With that macro missing, an actual PUMP_STORE=1
instance also rejects import/readback as a profile mismatch. `import_gx_context_with_clip_witness` is the new wrapper:
it requires existing clean-scope validation plus the complete sidecar witness,
checks canonical mirror/RF consistency for the existing four mapped groups,
preflights, calls the unchanged original mapping, restores pumped state and
immediately verifies the old context and actual pumped storage/read views.
It checks metadata and time unchanged across the transaction.

The existing2632word schema, old host source hashes and accepted clean MKDS
context predicates are NOT changed. `clean_scope_validated` represents that
existing enclosing validator/source/capture proof, never permission to skip
it or substitute a hash-only blessing. Root must wire/review that proof and
source/profile binding before calling the wrapper. Current canonical seed
has only four TempVertexBuffer groups and no O/I sidecar: enabled use remains
rejected until full source evidence is supplied (or a separately qualified
exact-scope liveness adapter is provided). No general/active restore support,
synthetic canonical fields or game acceptance is added.

Root also retains enclosing CPU/cache/transport/publication drain and clock
freeze/phase certification. A held bit/current low clock alone is not proof
of future clock suspension. This local helper supplies no scheduler or
canonical source translator.

## Execution and reproduction

`run.py` only copies/hashes inputs by default. It does NOT compile or simulate.
After Root assigns a new lease, run modes sequentially NI10/jobs1/threads1:

    python3 sim/gpu3d/clip_import/run.py --mode healthy --execute --lease ASSIGNED
    python3 sim/gpu3d/clip_import/run.py --mode wrong-field --execute --lease ASSIGNED
    python3 sim/gpu3d/clip_import/run.py --mode bad-phase --execute --lease ASSIGNED
    python3 sim/gpu3d/clip_import/run.py --mode phase-guard-mutant --execute --lease ASSIGNED
    python3 sim/gpu3d/clip_import/run.py --mode partial-witness --execute --lease ASSIGNED
    python3 sim/gpu3d/clip_import/run.py --mode pending --execute --lease ASSIGNED
    python3 sim/gpu3d/clip_import/run.py --mode active --execute --lease ASSIGNED
    python3 sim/gpu3d/clip_import/run.py --mode missing-reads --execute --lease ASSIGNED

Smallest paired actual clip STORE_PUMP0/1 test: four raw vertices, one normal
clip launch immediately after atomic import, held queue/real RF feedback,
first consumed arithmetic state, public write data/address/result/order and
strict cycle comparison. All32groups/full bits/O-I are deposited/read back;
no post-import settling tick. Test case is a component fixture, not a new
canonical/game capture. Wrong-field changes an actual staged bridge bank0
source from R to G; raw readback/internal observers are deferred so only a
PUBLIC mismatch counts. Wrong-phase is a contract oracle: healthy invalid
phase rejects, then actual removal of post_m check must be detected as an
unsupported admission. It is not claimed as a public phase-shift witness.
Other modes reject incomplete payload/reads, pending write and active clip.

Local results are listed below. Required Root review/gates: HDL builds,
first-use/mutation outcomes, wrapper/clean-validator integration and source
binding, no partial mutation on rejection, exact physical import semantics
if a native backend is later requested, then existing import/STA/DS budget.

## Local results (portable clip bridge, not full context/game integration)

| Row | Result |
|---|---|
| Faithful default capture → enabled import → first ordinary clip |PASS214cycles/71RFwrites/4neighbours, state/public data/order/cycles exact; all160backing words+10held reads captured and read back |
| Actual staged R-bank source changed to G |PUBLIC CWD mismatch cycle55 old10030000/new10130000; raw readback/internal observers deferred |
| Actual post_m guard removed |Unsupported phase admission caught by contract oracle |
| Bad phase, pending write, active clip, partial payload, missing reads/profile |All six reject at expected barriers |
| Default source replica conflict |Capture rejects before destination deposit |
| Adversarial held O/I poison |PASS214cycles; first late neighbour cycle54; ordinary M refresh occurs before consumption |

The first fixture used $finish inside a loop and then fell through a timeout;
an attempted named-disable also fell through under this Verilator version.
The final fixture uses a completion flag and $finish after the loop; the
runner rejects fatal/error output even with exit0. Both rejected logs remain
in the capsule; they are not successful tests. Production bridge was unchanged.
Negative preflight rows before the exporter addition reuse an exact literal
prefix; the new read-only exporter is not reached by those rejections.

`proof.tar.gz` contains staged source/header/test inputs, logs, commands,
hashes, receipts, source-specific held-read analysis and binding audit.
`verify.py` checks this offline. Original runner receipts sometimes include
prior log hashes from a reused directory; only staged HDL input hashes are
used for source validation, and the capsule manifest seals final logs. The
runner now records input sources only.

## Faithful sidecar route for Root review

`clip_capture_legacy_witness` READS all five32word old mirrored banks and ten
held read outputs from the DEFAULT source. It rejects contradictory mirrors,
unknown values, active/uncertified phase and uncertified last-SYS-write absence;
it makes no source writes or clock advances. `capture_gx_context_clip_witness`
also checks every value against both actual source RF replicas. The clip-
level capture has executed; that full RF/context wrapper remains Root's
integration/review gate, not a claimed full-project proof.

Root can bind a sidecar to an actually qualified default-source clean-context
capture: retain parent atomic digest and existing clean-scope validation,
exact source/profile and destination/profile, frozen SYS/FAST phase/E-next
certificate, observed last aligned-SYS write absence, and captured payload/
held-read/readback digests. Call the read-only capture helper, serialize its
actual returned values, then use the destination witness wrapper with real
immediate readback and first-use comparison. Never manufacture missing28groups
or O/I from zeros or an arbitrary current RF address. A stopped/default core
capture is evidence of that source state, not an automatic DS/game approval.

Current canonical seed still lacks this sidecar. Host schema and original
source binding were NOT refreshed; binding-audit.json explicitly lists d39
mismatches with the legacy target. Root must review current repaired public
source and the existing accepted mapping before rebinding, not just update
hashes. No active/general savestate support, game/import acceptance or STA
promotion follows from these local tests.

## Narrow held-read liveness

The exact clip FSM, conservatively allowing every conditional branch,
reaches S_CM2 no earlier than4SYS transitions and S_NB2 no earlier than5
from S_IDLE. Those are the late-held consumers. The child input bank's first
three live products use unchanged earlyXYZ; late fields enter only go-gated
captures at S_NB2. Thus an ordinary M refresh exists before any late-held
read use under the admitted idle/E-next/no-pending boundary. Other arithmetic
and early-field state remain existing separate obligations. This does not
prove anything about the28missing payload groups or justify a general
checkpoint. The strict API continues requiring full captured O/I and payload;
no acceptance predicates were relaxed on the strength of the liveness row.
