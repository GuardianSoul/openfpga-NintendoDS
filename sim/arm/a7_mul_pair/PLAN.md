# ARM7 native-pair multiplier service/cost screen

Before helper branch169264df; joined producer control maina7e1c5a9.
Coordinator authorizes only ARM7 multiplier-expression substitution after
producer join; no phase/retirement edits. Main speed-status reread; accepted
scopes remain closed. Branch remains compact pinned architecture; tests also
apply the literal arithmetic substitution to the joined main ARM7 source,
without importing unrelated speed changes into this branch.

Adapt qualified1172/Raster83/169264df two-independent signed18x18 six-port
native donor. Do not replace ARM7 or change its timing/service law. Existing
ARM7 multiplication is signed33x33→66; signed extension is enabled only for
signed-long class. MUL/MLA low32, unsigned-long, signed-long and optional
64-bit accumulator must remain literal. The new combinational helper splits
signed17 high and unsigned16 low, forms four exact partials in two pairs,
and reconstructs full66. No approximation, width/carry loss or arithmetic
shift/tolerance change. Every original accumulator expression is retained.

Inputs opa/opb are live combinational values, not a faster-clock contract.
Helper adds zero clocks/registers/enables/resets; existing caller captures
results at unchanged edges. Throughput and latency remain purely
combinational; no phase/retirement/fetch/sound scheduling change. No memory
placement/shared-service change. Native inputs/results/clocks/active ports
are identical to the qualified donor; no inactive ties. Expected ARM7
3→2DSP is unmeasured. A35-bit middle sum and66-bit reconstruction adder
are now explicit fabric; upper two bits may prune because caller consumes
low64. Rough35+66carry-bit bound is about51carryALMs before pruning,
packing or displacement of existing logic; not measured ALMs or timing.
No newFF/RAM or operand muxes. ARM9 qualified code stays literal unchanged.

Proof: literal joined-before/candidate fallback/native contract plus independent
full66 product and literal optional64 accumulator; actual wrong native BY
partial must reach public CPU result. CPU fixtures compare original bus,
retirement, writebacks, CPSR and enabled passive metadata at identical clocks,
with fetch/data holds and reset. Test MUL/MLA/UMULL/UMLAL/SMULL/SMLAL,
flags, signed/unsigned boundaries, accumulator carry and conditional false
instructions. Reuse unchanged ARM9 native component/25DENSE/26ARM proofs;
legacyA7_DS0suite alone does not cover this dedicatedARM7 caller. No repeated
DS timing probe/accepted-private-WRAM screen. Root batches actual fit.

Largest-ALM frontier stays explicit:325-bit uop includes128bits of correlated
PC/link values, but live synthesized stage cost and late reconstruction
critical paths are unknown; no source-width saving booked. Decode is dynamic
in register-list/mode/exception/parameter fields, so whole-uop synchronousROM
is not a justified latency-preserving substitute. Seek actual live-cone cost
before changing speed-owner logic.

## Qualified result

All202178full66/native/fallback/oracle+accumulator cases pass.15dedicated
ARM7 cases compare before/native/fallback literally:785087retirements,
1406753public rows;14PASS and inheritedbpred7 budgetFAIL unchanged.
40independent operand/accumulator triples×6actualARMv4multiply forms check
results and NZ, repeated with memory holds. Actual nativeBY fault is caught
in full66 output (0x10001 vs1) and actual CPU lockstep retirement104/CPSR
and resultdead0001. All sequential caller logic is literal unchanged;
existing fixture startup reset is retained, with no new reset state.

Full-tree qlint/Python syntax/diff checks PASS. ARM9 code is byte-for-byte
unchanged before the appended helper, so its component/25DENSE/26ARM proofs
are reused. No3→2DSP or ALM saving is booked before actual Root same-seed
price. The unregistered middle+reconstruction+original accumulator chain
is a physical67MHz risk; no register insertion or blanket margin is accepted.
