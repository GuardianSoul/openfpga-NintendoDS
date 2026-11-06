# Narrow ARM7 STM4 metadata prototype

This adapts the existing request/accepted-DATA expressions and P7 posted
owner from the [source proposal](../../../docs/cpu-arm7-stm4-interface-20261102.md).
It introduces no memory service, timing charge, CPU stall/ACK control,
payload queue or physical packet change. The402-bit execution observer
remains disabled. cpu_domain forwards the narrow ports on the CPU clock;
P7 and root/fabric integration is separate.

arm7_ds.STM4_META and arm_cpu.A7_STM4_META default to0. The disabled and
shared-ARM7 routes output zero. The request contains exactly three bits:
valid plus beat0..3. Eligibility is an executed ARM/unconditional STMIA4,
S0/W0, base outside list/not PC, no PC in the list, aligned full-word MAIN.
There is no PC, benchmark address, register-mask or measured-cycle special
case. The separate stm4_accept event uses the CPU's actual list answer
state, including the existing phase/run hold.

arm7_stm4_owner defaults disabled and stores two independent three-bit
tags when enabled. write_admit must be the ACTUAL existing P7 posted-slot
admission; physical_ack must be its OLD busy/write/ACK completion.
cpu_accept is the CPU producer's qualified consume event. Metadata never
feeds those controls. On same-edge completion/admission, outputs describe
the old owner and state captures the new request after that edge.
CPU reset clears the answer owner; port reset clears both owners. A CPU
reset or fetch redirect cannot erase an older committed physical write.
The leaf adds six declared owner bits; mapped area/STA are unmeasured.

The directed harness uses eight real public CPU/P7 lanes: exact previous
source362fea1d, parameter default, explicit0, and1, each with the existing
SWP extension disabled/enabled. All original sequencer/datapath/PSR and
both32-word RF copies compare each edge. Functional interface/retirement,
accepted DATA, real RAM takes and complete backing compare independently.
The metadata oracle uses the assembled program's positive instruction
labels and an acceptance-driven beat counter, not the producer predicate.
Scalar, LDM, other P/U/W/S/count, base/PC, unaligned, conditional, WRAM and
Thumb variants are explicit negatives. The fixture uses private-WRAM code;
it does not claim MAIN instruction quad or native DS timing qualification.

Only one allocated NI10/j1/t1 worker may run:

    python3 sim/arm/stm4_meta/run.py --output FRESH_DIRECTORY --status CPU_STATUS
    python3 sim/arm/stm4_meta/run_cpu.py --output FRESH_CPU_DIRECTORY --verilator VERILATOR --status CPU_STATUS
    python3 sim/arm/stm4_meta/check_domain.py --output FRESH_DOMAIN_DIRECTORY

The directed controller compiles actual wrong-beat producer and wrong-owner
leaf mutations serially. They continue to the complete functional comparison
before the metadata checker rejects them. The CPU controller reuses retained
test inputs, runs25DENSE/tb_arm against the exact current-before CPU, and
keeps the inherited bpred7 result explicit. It never enables EXEC_META.

The sealed result is described in docs/cpu-arm7-stm4-metadata-20261102.md.
The offline replay accepts the result packet directory as its argument;
it verifies archived source, complete streams, mutations and retained gold
states without executing a simulator. No standalone fit, native baseline,
probe or source/timing change to an accepted scope is authorized here.
