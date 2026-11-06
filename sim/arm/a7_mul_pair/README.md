# Dedicated ARM7 two-pair multiplication

Replace only the combinational ARM7 product with a full66-bit helper using
the qualified independent native DSP pairs. The64-bit optional accumulator
and every sequential statement remain unchanged. No ARM9, memory, producer,
phase or retirement edits. Intended ARM7 DSP3→2 remains unmeasured.

The [plan](PLAN.md) records service, cost and donor before implementation.
[Summary](evidence/summary.json) and [full proof](evidence/result.json) pin
785087retirements/1406753public observations over15dedicatedARM7 cases:
14PASS plus unchanged inheritedbpred7 budgetFAIL. Literal joined-before
`a7e1c5a9`, native-contract and fallback agree on exact cycles, bus/writeback
order and architectural traces.40operand/accumulator triples×6multiply forms
also pass independent result/NZ assertions with ordinary and stalled memory.
202178unit cases preserve full66 arithmetic and64-bit accumulator carry.
The [actual partial fault](evidence/cpu-mutant.json) reaches CPU lockstep at
retirement104, without a timeout.

The branch keeps its pinned compact architecture. The test applies the exact
production arithmetic substitution onto joined main's ARM7 source; unrelated
producer changes are not imported into this branch. Root can apply the thin
caller change on top of its joined producer. ARM9's169264df helper is an
unchanged literal prefix; its native-component/25DENSE/26ARM proofs are reused.

Run `python3 sim/arm/a7_mul_pair/check.py`, then
`python3 sim/arm/a7_mul_pair/fault.py` on an allocated NI10/jobs1/threads1
worker. Native simulation is a transparent atom contract, not encrypted
vendor simulation. Actual native mapping, ALM/DSP trade and67MHz timing remain
Root's combined same-seed fit gate; no subset fit is queued. DS/game/audio
gaps stay open. Detailed source/inputs/models/logs/traces are archived in
`build/cpu-a7-mul-pair-evidence.tar.gz`; scratch is pruned after preservation.
