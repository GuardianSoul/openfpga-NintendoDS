# Test-only CPU commit producer

The [paired runtime gate](../../../docs/results/a7-logical-slot-pair-20261102/README.md)
now qualifies this producer with Memory's `087e3a66` receiver within its
documented protocol bounds:22positive cases, seven literal disabled controls
and one actual dropped-offer fault caught by P7. This is not a timing fix
or production enable. The existing `aae27031` finish/prepare transformer
is reused unchanged.

The transformer pins ARM7 input SHA256 `662c582f…357d4e` from59b/faf and
the original phase transformer `a9dc9b35…9f9272`. P7 SHA256
`0ce5fbcf…4fd457` matches Memory's frozen input. Use those leaves when
pairing; Memory087's older CPU copy does not include the accepted passive
MUL metadata and is not silently substituted. Preparation/qlint receipts
are retained unchanged in `cpu-source-preparation.json`; that historical
receipt predates the paired runtime result.

The local added signals are output `i_commit_valid`, output
`i_commit_addr[31:0]`, input `i_commit_accept`. They cover sequential ARM
MAIN only. `phase_trial` is fixed until reset. No public metadata, new
epoch/class signal, wait constant or service price is introduced.

Preparation latches the matching finished F owner's address plus4; the
simultaneous first-finish/start case captures that original completion's
address. The first offer bypasses at architectural consumption after the
internal work. If unaccepted, valid/address remain held through pause or
backpressure until accept/reset/redirect. A saved completed current F word
stays separate from the next logical owner. A next address leaving MAIN is
outside this subset and does not generate a commit.

Registered pending occupancy blocks another F consume/overwrite. Acceptance
updates registers only: it has no combinational route back to current
consume, pipeline progress or old-word readiness. Reset/redirect has final
priority. The local CPU-only-reset wrapper must OR CPU reset into P7's
logical redirect while retaining P7's physical reset low through real tail
ACK. Memory owns old-consume/new-capture priority and physical ownership.

The producer ledger checks first-offer provenance, held stability,
acceptance, pending overwrite and cancellation. `drop-unaccepted` and
`live-address` generate actual RTL faults. The paired gate catches
`drop-unaccepted`; `live-address` remains unrun. Disabled behavior,
same-edge acceptance, held backpressure, pause/redirect/reset, contention
and architectural state/data pass within the retained bounds. DS service
progression and the known mixed-MUL scaling error remain unresolved.
