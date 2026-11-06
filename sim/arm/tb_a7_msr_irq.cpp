// arm7_ds: an IRQ taken as an MSR that changes the mode or the I bit commits (rtl/arm/arm7_ds.sv). The entry reads
// cpsr, so it must wait a clock: the SDC gives cpsr's paths 2 clocks ("a 2-clock path's endpoint changed").
// Sweeps the IRQ's arrival over the loop below. Prints IRQs taken; the check's $error lines count the faults.
#include "Varm7_ds.h"
#include "verilated.h"
#include <cstdio>
static uint32_t m[1024];
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::fatalOnError(false);
    m[0x00 / 4] = 0xea00000e;   // b 0x40
    m[0x18 / 4] = 0xe25ef004;   // irq: subs pc, lr, #4
    m[0x40 / 4] = 0xe3a0c01f;   // mov r12, #0x1f (system mode, IRQ on)
    m[0x44 / 4] = 0xe3a02092;   // mov r2, #0x92  (IRQ mode, IRQ off)
    m[0x48 / 4] = 0xe12ff00c;   // msr cpsr_fsxc, r12
    m[0x4c / 4] = 0xe12ff002;   // loop: msr cpsr_fsxc, r2
    m[0x50 / 4] = 0xe12ff00c;   // msr cpsr_fsxc, r12
    m[0x54 / 4] = 0xeafffffc;   // b loop
    Varm7_ds t;
    t.reset_pc = 0; t.hivecs = 0; t.run = 1; t.fiq = 0; t.wake = 0; t.irq = 0; t.i_ok = 1; t.d_ok = 1; t.d_rdata = 0;
    t.rst = 1;
    for (int i = 0; i < 8; i++) { t.clk = 0; t.eval(); t.clk = 1; t.eval(); }
    t.rst = 0;
    int irqs = 0, wait = 40, sweep = 0;
    for (long c = 0; c < 400000; c++) {
        t.clk = 0; t.eval();
        t.i_rdata = m[(t.i_addr >> 2) & 1023];
        t.eval(); t.clk = 1; t.eval();
        if (t.dbg_retire && t.dbg_pc == 0x18) { irqs++; t.irq = 0; wait = 20 + (sweep++ % 41); }
        else if (wait && --wait == 0) t.irq = 1;
    }
    printf("irqs %d, pc %08x\n", irqs, t.dbg_pc);
}
