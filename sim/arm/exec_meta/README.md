# Passive ARM7 execution metadata

`arm7_ds.EXEC_META` and public `arm_cpu.A7_EXEC_META` default to zero. The
disabled output is all zero and the observation state is not instantiated.
The shared ARM7 route also returns zero. No consumer is connected in the
DS top, P7 or fabric.

The enabled `a7_exec_meta_t` output is sampled at the rising edge. It
reports actual fast register-shift and MUL/MLA substate advances, plus
accepted DATA with a request-time descriptor. It is not a logical N/S/I
sequencer, access admission, timing charge or service policy. Slow setup,
register-file read, generic E holds and denied ACKs are not labeled as
architectural internal cycles. Slow scalar/list/SWP accepted DATA is
reported through its existing owned answer state.

An instruction entering the fast E stage or the slow sequencer receives a
dynamic ordinal and its epoch, PC, instruction state, mode and decoded
kind. Redirect observations follow the existing `i_redirect`, including
S_FETCH restarts. Epoch increases on those steps; current data/execute
observations retain the pre-edge owner. Reset clears observation state.
Ordinals/epochs are diagnostic finite counters, not a new outstanding
transaction protocol or authorization to discard physical replies.

DATA direction, byte enables, payload, original and bus addresses are
captured on the first request and held through retries. They are not
reconstructed from answer-state `d_we`. First/last, beat index/count,
original/effective list masks, original P/U form, selected bank, user-bank
and PC flags, base register, writeback form/value and address-arithmetic
count accompany the accepted beat. The empty list has one actual PC beat
but writeback count16. SWP exposes its distinct owned read/write under one
instruction ordinal, using current `WRAM_SWP_PIPE` when enabled and the
existing fallback otherwise. Accepted read payload is the raw bus word;
load alignment/rotation remains the CPU's existing behavior.

Run the directed real-P7 proof with:

```
python3 sim/arm/exec_meta/run.py --public --output build/exec-meta/public
python3 sim/arm/exec_meta/run.py --variant last-mutant --output build/exec-meta/last-mutant
python3 sim/arm/exec_meta/run_cpu.py --output build/exec-meta/cpu --verilator build/tools/oss-cad-suite/bin/verilator
```

Each worker sets NI10, builds with one job and uses one simulation thread.
The mutation command deliberately exits on an incorrect list-last flag;
its unchanged CPU outputs must compare before the metadata rejection.
Use new output directories. The controller binds the exact before source
`fe6bdd4e`, which includes the current SWP extension; old source-audit line
numbers do not define this producer. The result packet records final
commands, source/input/model hashes and reaped process receipts.
