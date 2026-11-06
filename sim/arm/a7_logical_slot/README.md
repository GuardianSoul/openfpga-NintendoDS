# Test-only P7 acceptance boundary

This source transformer adds a three-signal local boundary to a frozen copy
of P7; it changes no production RTL or public profile. CPU owns its producer.
Memory owns P7's logical-slot acceptance and observation ledger. The
[receiver-only gate](../../../docs/results/a7-logical-slot-receiver-20261102/README.md)
passes12positive cases, literal valid0 comparisons and two actual faults.
The [paired CPU gate](../../../docs/results/a7-logical-slot-pair-20261102/README.md)
now passes22positive cases and one actual producer fault, with original
fixture failures retained. Existing `flow_left` prices remain controls,
not DS debt proof.

| Added signal | Direction at P7 | Meaning |
| --- | --- | --- |
| `i_commit_valid` | input | Sequential ARM MAIN access committed after internal work; held until acceptance or cancellation |
| `i_commit_addr[31:0]` | input | Prepared next address, stable with held valid |
| `i_commit_accept` | output | That edge captures exactly one logical owner |

Existing `i_addr`, `i_arm`, `i_consume`, `i_redirect`, `flow_v`, `flow_a`,
`flow_ready` and internal generation are reused. No sequence/epoch bus is
added for this sequential-only subset. Matching completed old consumption
can free the logical slot on the acceptance edge. Ordinary legacy capture
is suppressed while an explicit commit is offered. Old consumption clears
first, new acceptance captures second, and redirect/reset wins. Returned
old payload remains CPU-owned until its architectural consumption.

CPU must retain valid/address after the intent edge until acceptance; a
one-edge intent that clears preparation unconditionally is insufficient.
Preparation alone must not assert commit or a new physical request. For a
CPU-only reset, the local fixture ORs that reset into P7's existing
`i_redirect`, leaving P7's port reset low so the actual physical packet
continues through its real final ACK. The producer cancels its pending offer.

The observation-only ledger checks held-owner stability, accepted next
storage, matching same-edge turnover, cancellation priority, and physical
header stability through actual ACK. `drop-capture` leaves the actual
acceptance visible but suppresses its RTL capture; `consume-wins` moves the
capture before the old consume clear. Both require an actual caught fault
in the paired CPU/P7 gate. Both are caught in the receiver-only fixture;
this does not yet qualify the CPU producer or its local wiring.

The paired gate combines CPU`d006ad38` with this receiver, compares disabled
behavior literally to its preceding control, and checks held backpressure,
one acceptance per request, same-edge turnover, pause, redirect, CPU-only
reset, ARM9 contention, architectural state/data and actual descriptor
ownership. Its actual dropped-CPU-offer mutation is caught by P7. Full
native timing and DS service progression remain separate gates. Root owns
any qualified default-off forwarding.

`prepare_receiver.py` freezes a small receiver-only fixture without starting
a worker. The fixture offers a request while the existing logical owner is
occupied, holds it through checked backpressure, then consumes that matching
finished owner on the acceptance edge. Further cases cover pause, redirect,
CPU-only reset during an actual owned PSRAM read, fresh-epoch readback and32
checked scalar ARM9 reads. The generic receiver offer deliberately arrives
before the old owner is free; it does not assert that a real CPU commits
before its internal work finishes. CPU's paired producer gate is retained
separately in the linked paired result.

Once allocated, `run_receiver.py` builds four models serially: preceding
P7 with only unused compatibility ports, the new receiver, and two actual
capture/priority mutations. Twelve positive runs include literal valid0
data/edge/pin comparisons; both fault models must fail their real accepted
owner check. NI10/j1/t1 and the pinned global capacity guard apply. These
sources produced the retained receiver-only result. The executed driver is
frozen in its evidence packet; the current driver also removes completed
compiler scratch before FETCH, retaining model binaries and input receipts.
