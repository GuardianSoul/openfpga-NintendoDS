# One full-width ARM7 product

One signed33×33→66 product replaces the separate signed/unsigned32-bit
source products. The upper input bit is enabled only for signed long
multiply. The original low64 result, optional64-bit accumulator,
combinational slow-path use and every-clock `prod_q` capture remain.
There are no new registers, issue rules, timing prices or producer/P7
changes. Actual DSP/ALM gain and physical timing await a future batched fit.

`prove.py --output DIR` binds the exact old/current production block and
proves all128 operand/accumulator bits plus every long/signed/accumulate
choice. It splits only the signed-long Boolean; both domains are UNSAT.
The sign-loss counterexample must be SAT. The unsplit first attempt's
timeout is retained as a failed method, not an acceptance result.

`run.py --output DIR` exercises before/current producer-off/current
producer-on triples, for both existing SWP options, through actual P7.
The before producer is enabled separately and must match the new enabled
producer on every edge. Six normal/retry/IRQ/reset/pause cases retain full
CPU/RF/state, original outputs, physical takes and backing memory. Each
lane also checks192 UMULL/SMULL/UMLAL/SMLAL results and N/Z flags against
independent arbitrary-precision arithmetic, including sign and full-width
accumulate carry/wrap boundaries.

`run.py --variant sign-mutant --output DIR` compiles actual RTL with the
first operand's sign extension suppressed. The state comparator must catch
it. `run_cpu.py --output DIR --verilator PATH` runs25DENSE/26tb_arm pairs
against current before `c25c2ed3`, keeping inherited `bpred7` explicit.
Run these serially under the coordinator's single NI10/j1/t1 lease. All
output directories must be new. No command queues a fit.
