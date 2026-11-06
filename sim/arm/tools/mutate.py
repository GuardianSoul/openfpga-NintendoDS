#!/usr/bin/env python3
"""Check that the ARM test set catches deliberate bugs (make arm-mutate).

Each mutation is applied to a copy of rtl/arm, built with Verilator and run
through run_tests.py. A mutation that every test passes is reported as
SURVIVED, which means the test set has a gap.
"""
import os
import shutil
import subprocess
import sys

MUTATIONS = [
    ("clz off by one", "arm_core.sv",
     "lz = 6'd31 - i[5:0]", "lz = 6'd30 - i[5:0]"),
    ("no E2 bypass of the previous uop on port A", "arm_core.sv",
     "assign e2_a = e2_sa[1] ? w_wd : e2_sa[0] ? wbq_d : e2_va;",
     "assign e2_a = e2_sa[0] ? wbq_d : e2_va;"),
    ("no E2 bypass of the write two uops back on port B", "arm_core.sv",
     "assign e2_b = e2_sb[1] ? w_wd : e2_sb[0] ? wbq_d : e2_vb;",
     "assign e2_b = e2_sb[1] ? w_wd : e2_vb;"),
    ("no load-use interlock", "arm_core.sv",
     "assign hazard = fresh && ll_v[1] &&", "assign hazard = 1'b0 && ll_v[1] &&"),
    ("RRX uses the stale C flag", "arm_core.sv",
     "assign cfwd = (w_fw && w_flags == FL_DP) ? w_c : cpsr[1][29];",
     "assign cfwd = cpsr[1][29];"),
    ("mispredicted branch not corrected", "arm_core.sv",
     "if (e3.valid && !x2_rdr && e3.pred && !e3_exec) begin", "if (1'b0) begin"),
    ("LSR #32 carry from bit 0", "arm_core.sv",
     "          e1_keep = 32'h0;\n          e1_csel = CS_X31;",
     "          e1_keep = 32'h0;\n          e1_csel = CS_R0;"),
    ("ARMv5 LDM base writeback rule dropped", "arm_core.sv",
     "fwb = ins[21] && base_in && v5c &&", "fwb = 1'b0 && base_in && v5c &&"),
    ("ARMv5 LDR/POP pc does not interwork", "arm_core.sv",
     "u.pct = v5c ? PT_DATA0 : PT_KEEP;", "u.pct = PT_KEEP;"),
    ("Thumb BLX register decodes as BX", "arm_core.sv",
     "((hw[7] && v5c) ? C_BLXR : C_BX)", "C_BX"),
    ("ARM7 TSTP legacy CPSR restore dropped", "arm_core.sv",
     "if (rd == 4'hF && !v5c) begin", "if (1'b0) begin"),
    ("ARM7 odd LDRH does not rotate", "arm_core.sv",
     "else           ld_val = {h[7:0], 16'h0, h[15:8]};", "else           ld_val = {16'h0, h};"),
    ("LDM rotates unaligned words", "arm_core.sv",
     "w_alo      <= e3.norot ? 2'b00 :", "w_alo      <= 1'b0 ? 2'b00 :"),
    ("SMLAxy does not set Q", "arm_core.sv",
     "w_q        <= ((e3.flags == FL_Q) && add_v) ||", "w_q        <= 1'b0 ||"),
    ("exception entry does not save the SPSR", "arm_core.sv",
     "spsr[1][spsr_idx(e3.exc_mode)] <= cur_cpsr;", ";"),
    ("IRQ ignores the I bit", "arm_core.sv",
     "irq_r[1] && !cpsr[1][7]", "irq_r[1]"),
    ("long multiply loses the low-half carry", "arm_core.sv",
     "temp_c[0] <= w_tc_val;", "temp_c[0] <= 1'b0;"),
    ("STM ARMv4 base written at the last transfer", "arm_core.sv",
     "u.wen = ins[21] && (v5c ? lastx : firstx);", "u.wen = ins[21] && lastx;"),
    ("rotating temp_wb loses its value after two cycles", "arm_core.sv",
     "temp_wb[0] <= temp_wb[1]; temp_wb[1] <= temp_wb[0];", "temp_wb[1] <= temp_wb[0];"),
    ("second instruction-buffer entry never moves up", "arm_core.sv",
     "ib_v[0] <= ib1_v[1];", "ib_v[0] <= 1'b0;"),
    ("empty ARMv4 register list starts at r0", "arm_core.sv",
     "((c_ins[15:0] == 16'h0) ? 4'd15 : lowest16(c_ins[15:0]))", "lowest16(c_ins[15:0])"),
    # ARM9 memory system (arm9_mem.sv)
    ("write-back store hit also written to memory", "arm9_mem.sv",
     "if (wd_cach && wd_hit && wd_buf) begin\n          wd_store_cache = 1'b1;",
     "if (1'b0) begin\n          wd_store_cache = 1'b1;"),
    ("dirty bit never set", "arm9_mem.sv",
     "qw_tag  <= wd_store_cache && wd_buf;", "qw_tag  <= 1'b0;"),
    ("clean does not write the line back", "arm9_mem.sv",
     "if (hit && lw[DTW] && cmo_op[6:3] != 4'd6) st <= S_EVRD;",
     "if (1'b0) st <= S_EVRD;"),
    ("MPU ignores data permissions", "arm9_mem.sv",
     "wd_abort = mpu_en && !(found && ok);", "wd_abort = 1'b0;"),
    ("MPU uses the lowest matching region", "arm9_mem.sv",
     "for (int n = 0; n < 8; n++)\n      if (ren[n] && ((w_addr", "for (int n = 7; n >= 0; n--)\n      if (ren[n] && ((w_addr"),
    ("no prefetch aborts", "arm9_mem.sv",
     "i_abort = mpu_en && !(found && ap_ok(iap[idx*4 +: 4], f_priv, 1'b0));", "i_abort = 1'b0;"),
    ("DTCM base does not move", "arm9_mem.sv",
     "dtcm_base <= w_wdata[31:12] & tmask_of(w_wdata[5:1]);", "dtcm_base <= dtcm_base;"),
    ("I-cache line invalidate does nothing", "arm9_mem.sv",
     "imask[x] <= it_aq[x*ILW + ITW] && (", "imask[x] <= 1'b0 && ("),
    ("ITCM data writes lost", "arm9_mem.sv",
     "itcm_we = pw_itcm ? pw_be : 4'h0;", "itcm_we = 4'h0;"),
    ("no forwarding of a pending store to the next load", "arm9_mem.sv",
     "    if (same && !w_cp)", "    if (1'b0)"),
    ("store dirty bit written to way 0's lane", "arm9_mem.sv",
     "dt_we = pw_tag ? ((WAYS+1)'(1) << pw_way) : '0;", "dt_we = pw_tag ? (WAYS+1)'(1) : '0;"),
    ("CP15 read-back reads the neighbouring entry", "arm9_mem.sv",
     "  assign cprb_q = cprb_v[cprb_ra] ? cprb[cprb_ra] : 32'h0;", "  assign cprb_q = cprb_v[cprb_ra] ? cprb[cprb_ra ^ 4'd1] : 32'h0;"),
    ("CP15 read-back: the c9 region is stored unformatted", "arm9_mem.sv",
     "    if (w_crn == 4'd9 && w_crm == 4'd1)\n", "    if (1'b0)\n"),
    ("victim lane taken from the neighbouring way", "arm9_mem.sv",
     "  assign tlane = dlane(trow, vway);", "  assign tlane = dlane(trow, vway ^ 1'b1);"),
    ("D fill leaves the round-robin counter", "arm9_mem.sv",
     "dt_we = ((WAYS+1)'(1) << vway) | ((WAYS+1)'(1) << WAYS);  // and the counter", "dt_we = ((WAYS+1)'(1) << vway);  // and the counter"),
    ("I line invalidate clears every way", "arm9_mem.sv",
     "it_we = {1'b0, imask};", "it_we = 5'b01111;"),
    ("line fill overtakes the write buffer", "arm9_mem.sv",
     "if (wbuf_v) st <= S_WDRAIN;\n          else if (dp_v) begin",
     "if (wbuf_v && !dp_v) st <= S_WDRAIN;\n          else if (dp_v) begin"),
    ("multiplier middle partial products dropped", "arm_mul.sv",
     "r_mid <= {p_hl[33], p_hl} + {p_lh[33], p_lh};", "r_mid <= 35'd0;"),
    ("replay restarts the instruction instead of the uop", "arm_core.sv",
     "ustep[1] <= x_step;", "ustep[1] <= 2'd0;"),
    ("a replayed uop does not put temp_addr back", "arm_core.sv",
     "        temp_addr[1] <= x_taddr;", ""),
    ("a replayed uop still writes its register", "arm_core.sv",
     "assign rf_we = x_go && !x_replay && (x_wen || x_abort);",
     "assign rf_we = x_go && (x_wen || x_abort);"),
    ("an IRQ taken between a refused access and its replay", "arm_core.sv",
     "&& !cpsr[1][7] && !rh[1];", "&& !cpsr[1][7];"),
    ("pending fetch address not held", "arm9_mem.sv",
     "if (!ip_v && !busy_i) ip_a <= f_addr;", "ip_a <= f_addr;"),
    ("pending data address not held", "arm9_mem.sv",
     "if (!dp_v && !busy_d) begin\n        dp_a", "if (1'b1) begin\n        dp_a"),
    ("maintenance op overwritten by any access", "arm9_mem.sv",
     "if (w_cp && cp_isop && !dp_v && !busy_d) begin", "if (!dp_v && !busy_d) begin"),
    ("load data ignores the cacheable bit", "arm9_mem.sv",
     "d_sel_h = !w_cp && !wd_itcm && !wd_dtcm && wd_cach && wd_hit;", "d_sel_h = !w_cp && !wd_itcm && !wd_dtcm && wd_hit;"),
    ("forwarding merge skipped on the cache-hit candidate", "arm9_mem.sv",
     "          h[b*8 +: 8] = pw_d[b*8 +: 8];\n", ""),
    ("DTCM load data from the cache path", "arm9_mem.sv",
     "else if (wd_dtcm) d_rdata = dtcm_bq;", ""),
    ("13-bit PSR storage loses the Q bit", "arm_core.sv",
     "    return {p[12:8], 19'h0, p[7:0]};", "    return {p[12:9], 20'h0, p[7:0]};"),
    ("13-bit PSR storage loses the T bit of an SPSR", "arm_core.sv",
     "      for (int k = 0; k < 5; k++) spsr[c][k] = psr32(spsr_s[c][k]);",
     "      for (int k = 0; k < 5; k++) spsr[c][k] = psr32(spsr_s[c][k]) & ~32'h20;"),
    ("IB: PD writes entry 0's slot while it is busy", "arm_core.sv",
     "    if (pd_go) ibm[{te, ib_h[0] ^ ib_v[0]}] <= pd_e;", "    if (pd_go) ibm[{te, ib_h[0]}] <= pd_e;"),
    ("IB: entry 1 does not move up", "arm_core.sv",
     "          ib_h[0] <= !ib_h[1];", "          ib_h[0] <= ib_h[1];"),
    ("SPSR: exception entry not written", "arm_core.sv",
     "    se_v <= !rst && e3_exec && e3.exc;", "    se_v <= 1'b0;"),
    ("SPSR: data abort written to the IRQ bank", "arm_core.sv",
     "sp_wa = {to, 3'd3}; sp_wd = sa_d;", "sp_wa = {to, 3'd2}; sp_wd = sa_d;"),
    ("SPSR: a first MSR leaves the other lane undefined", "arm_core.sv",
     "        sp_wf = sp_wf || sp_wc; sp_wc = sp_wf || sp_wc;\n", ""),
    ("branch predictor never written", "arm_core.sv",
     "    bp_we = w_bp;", "    bp_we = 1'b0;"),
    ("predictor counter does not saturate", "arm_core.sv",
     "n = w_bp_tk ? ((w_bp_ctr == 2'd3) ? 2'd3 : w_bp_ctr + 2'd1)", "n = w_bp_tk ? (w_bp_ctr + 2'd1)"),
    ("Thumb BL suffix not redirected in PD", "arm_core.sv",
     "    pd_bl2 = p_thumb && bl_v[0] &&", "    pd_bl2 = 1'b0 && bl_v[0] &&"),
    ("BL prefix kept across a redirect", "arm_core.sv",
     "        bl_v[1] <= 1'b0;\n        ib_v[1] <= 1'b0;", "        ib_v[1] <= 1'b0;"),
    ("BLX suffix redirected in PD leaves the T bit set", "arm_core.sv",
     "          if (e3.clr_thumb) c[5] = 1'b0;", ""),
    ("ARM7 HALTCNT ignored", "arm_cpu.sv",
     "    .halt_req({halt7, 1'b0}), .wake({wake7, irq[0]}),", "    .halt_req(2'b00), .wake({wake7, irq[0]}),"),
    ("ARM7 HALTCNT decoded at the wrong word", "arm_cpu.sv",
     "a7_d_addr[31:2] == 30'h010000C0", "a7_d_addr[31:2] == 30'h010000C1"),
    ("ARM7 halt ends only on its IME-gated IRQ", "arm_cpu.sv",
     "    .halt_req({halt7, 1'b0}), .wake({wake7, irq[0]}),", "    .halt_req({halt7, 1'b0}), .wake(irq),"),
    # the 2-way ARM9 caches (built with -GARM9_WAYS=2)
    ("2-way: set/way operations ignore way bit 1", "arm9_mem.sv",
     "    return (WAYS == 4) ? v[DSB+4:5] : {v[31], v[DSB+3:5]};", "    return v[DSB+4:5];",
     ["-GARM9_WAYS=2"]),
    ("2-way: fills always take way 0", "arm9_mem.sv",
     "            dt_we = ((WAYS+1)'(1) << vway) | ((WAYS+1)'(1) << WAYS);  // and the counter",
     "            dt_we = (WAYS+1)'(1) | ((WAYS+1)'(1) << WAYS);  // and the counter", ["-GARM9_WAYS=2"]),
    # RAM model (arm9_ram.sv, simulation side)
    ("RAM port B read ignores the address", "arm9_ram.sv",
     "else                             b_q[l*LANE_W +: LANE_W] <= mem[b_addr];",
     "else                             b_q[l*LANE_W +: LANE_W] <= mem[a_addr];"),
]


def main():
    verilator, build = sys.argv[1], sys.argv[2]
    assets = sys.argv[3]
    only = sys.argv[4] if len(sys.argv) > 4 else ""     # run the mutations whose name has this
    root = os.path.join(build, "mutate")
    survived = 0
    for i, (name, fname, old, new, *extra) in enumerate(MUTATIONS):
        vflags = extra[0] if extra else []
        if only not in name:
            continue
        d = os.path.join(root, f"m{i}")
        shutil.rmtree(d, ignore_errors=True)
        shutil.copytree("rtl/arm", os.path.join(d, "rtl"))
        p = os.path.join(d, "rtl", fname)
        src = open(p).read()
        if src.count(old) != 1:
            print(f"ERROR  {name}: pattern found {src.count(old)} times")
            survived += 1
            continue
        open(p, "w").write(src.replace(old, new))
        rtl = [os.path.join(d, "rtl", f) for f in
               ("arm_pkg.sv", "arm_regfile.sv", "arm_mul.sv", "arm_thumb.sv", "arm_core.sv",
                "arm9_ram.sv", "arm9_mem.sv", "arm_cpu.sv")]
        r = subprocess.run([verilator, "--binary", "-j", "0", "-O3", "--x-assign", "fast",
                            "--x-initial", "fast", "-Wno-fatal", "-Wno-WIDTHEXPAND",
                            "-Wno-WIDTHTRUNC", "-Wno-UNUSEDSIGNAL", "--top-module", "tb_arm",
                            *vflags, "-Mdir", os.path.join(d, "obj"), *rtl, "sim/arm/tb_arm.sv"],
                           capture_output=True, text=True)
        if r.returncode:
            print(f"ERROR  {name}: build failed")
            survived += 1
            continue
        r = subprocess.run([sys.executable, "sim/arm/tools/run_tests.py", "--sim",
                            os.path.join(d, "obj", "Vtb_arm"), "--build", build,
                            "--assets", assets], capture_output=True, text=True)
        caught = [l.split()[1] for l in r.stdout.splitlines() if l.startswith("FAIL")]
        if caught:
            print(f"caught    {name}: {' '.join(caught)}")
        else:
            print(f"SURVIVED  {name}")
            survived += 1
    shutil.rmtree(root, ignore_errors=True)
    if survived:
        sys.exit(1)


if __name__ == "__main__":
    main()
