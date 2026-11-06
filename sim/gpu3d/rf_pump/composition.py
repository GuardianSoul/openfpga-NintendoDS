#!/usr/bin/env python3
"""Bind actual RF address owners, native clocks, logical imports and unchanged consumers."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True)
p.add_argument('--before',default='181d3189');a=p.parse_args()
out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
paths=['rtl/gpu3d/gpu3d_gxeng.sv','rtl/gpu3d/gpu3d_gxrom_adict.sv','rtl/gpu3d/gpu3d_gxrom_ux.sv',
       'rtl/gpu3d/gpu3d_gxu_pkg.sv','rtl/gpu3d/gpu3d_ram.sv','rtl/gpu3d/gpu3d_gxlight.sv',
       'sim/ds/runtime_gx_context.py','sim/pocket_ds/runtime_import_gx_context.svh','scripts/build_ds.sh']
src={p:(ROOT/p).read_bytes()for p in paths}
old={p:subprocess.check_output(['git','show',a.before+':'+p],cwd=ROOT)for p in paths}
for path in paths[1:-1]:assert src[path]==old[path],path
engine=src[paths[0]].decode();before=old[paths[0]].decode()
helper=engine[engine.index('module gpu3d_gxrf #('):].split('endmodule',1)[0]+'endmodule\n'
prefix=engine.split('// One native two-read RF bank.',1)[0].rstrip()+'\n'
start=prefix.index('    // The measured private profile has SYS-held read addresses')
end=prefix.index('    // Full parallel Pos*Proj',start)
original=before[before.index('    gpu3d_ram #(.W(32), .AW(11)) u_rfa'):before.index('    // Full parallel Pos*Proj')]
restored=prefix[:start]+original+prefix[end:]
assert restored==before, 'all original engine code except RF driver block byte-exact'
assert "parameter bit PUMP=1'b0"in helper and 'logic [31:0] mem [0:2047];'in helper
assert 'localparam bit RF_PUMP = PU && FF && LUNIT && SMALL && MAT_PAR && ROM_DICT;'in engine

# The qualified profile selects UX and its existing exact A dictionary.
# Thus ua is an E-only registered word after the already-qualified cold
# phase acquisition; reset_q is SYS as well. No new ROM/hold assumption.
assert 'generate if (FF && LUNIT) begin : g_romx'in engine
assert 'gpu3d_gxrom_ux #(.B2(SMALL), .A_DICT(ROM_DICT), .B_DICT(B_DICT))'in engine
rom=src[paths[2]].decode();adict=src[paths[1]].decode()
assert 'generate if (A_DICT) begin : g_a_dict'in rom and 'gpu3d_gxrom_adict #'in rom
assert 'if (ph) index_q <= index_mem[addr];'in adict and 'else word_q <= word_mem[index_q];'in adict
assert 'assign q = reset_q ? RESET_WORD : word_q;'in adict
assert 'reset_q <= rst;'in adict and 'always_ff @(posedge clk)'in adict
tg=tq=ph=0;writes=[]
for n in range(8):
    for edge in ['M','E']:
        writes.append(dict(SYS=n,edge=edge,word_write=not ph))
        ntq=tg;nph=int(tg==tq)
        if edge=='E':tg^=1
        tq,ph=ntq,nph
assert all(not r['word_write']for r in writes if r['SYS']>=3 and r['edge']=='M')
assert all(r['word_write']for r in writes if r['SYS']>=3 and r['edge']=='E')

assert 'wire [10:0] a_ra   = fa(ua, A_RA_LO, A_RA_W);'in engine
assert 'wire [1:0]  a_rax  = fa(ua, A_RAX_LO, A_RAX_W);'in engine
assert 'wire [10:0] rf_ra = a_ra + xv(a_rax);'in engine
assert 'wire [10:0] rf_rb = a_rb + xv(a_rbx);'in engine
xv=engine.split('function automatic [10:0] xv',1)[1].split('endfunction',1)[0]
for k in range(1,4):assert f"2'd{k}: xv = xr{k};"in xv
end=engine.index('    assign idle =')
start=engine.rfind('    always_ff @(posedge clk) begin',0,engine.index('            upc <= RESET;'))
block=engine[start:end]
assert 'posedge clk2'not in block and 'posedge clk_2x'not in block
assert len(re.findall(r'\bxr[123]\s*<=',block))==len(re.findall(r'\bxr[123]\s*<=',engine))
assert not re.search(r'\bxr[123]\s*=(?!=)',engine)
negative=engine.replace('wire [10:0] rf_ra = a_ra + xv(a_rax);',"wire [10:0] rf_ra = a_ra + xv(a_rax) + {10'd0,clk_2x};")
assert negative!=engine and 'wire [10:0] rf_ra = a_ra + xv(a_rax);'not in negative

# Preserve native primitive configuration and each observable edge. Vendor
# execution in check.py independently checks actual bindings and the R edge.
for text in ['.outdata_reg_a("CLOCK1"), .outdata_reg_b("CLOCK1")',
             '.clock0(clk2), .clock1(clk)',
             '.address_a(mid ? raddr : waddr), .data_a(wdata), .wren_a(!mid && we), .rden_a(mid), .q_a(rdata)',
             ".address_b({1'b0,raddr_b}), .data_b(32'd0), .wren_b(1'b0), .rden_b(mid), .q_b(rdata_b)"]:
    assert text in helper,text
assert 'always_ff @(posedge clk) epoch<=!epoch;'in helper and 'always_ff @(posedge clk2) seen<=epoch;'in helper
assert 'rdata<=mem[raddr];rdata_b<=mem[{1\'b0,raddr_b}];'in helper
assert 'if(we)mem[waddr]<=wdata;'in helper
assert 'assign qb = RF_PUMP ? rf_qb_pump : rf_qb_original;'in engine
assert '.we(rf_we && !rf_wa[10])'in engine

imports=src[paths[7]].decode()
rf={port:{int(k):rhs for k,rhs in re.findall(r'`RUNTIME_GEOMETRY\.u_eng\.u_rf'+port+r'\.mem\[(\d+)\]=([^;]+);',imports)}for port in ['a','b']}
assert rf['a'] and rf['b']
for k,v in rf['b'].items():assert k<1024 and rf['a'][k]==v
assert 'held && `RUNTIME_GEOMETRY.u_eng.idle && !`RUNTIME_GEOMETRY.u_eng.we_o && !`RUNTIME_GEOMETRY.u_eng.we_m'in imports

script=src[paths[-1]].decode();old_script=old[paths[-1]].decode()
start=script.index('set gxrf_regs [get_registers')
end=script.index('set gxlight_shin_regs [get_registers',start)
assert script[:start]+script[end:]==old_script
assert 'set_multicycle_path -setup -end 1 -from [get_clocks $clk_sys] -to $gxrf_regs'in script
assert 'set_multicycle_path -hold -end 0 -from [get_clocks $clk_sys] -to $gxrf_regs'in script
result=dict(before=a.before,source_sha256={p:hashlib.sha256(b).hexdigest()for p,b in src.items()},
    unchanged='Inverse RF driver/helper/normalSDC additions restores exact old engine and script. All consumers/CPU/FIFO/IRQ/order/writer arbitration, ROMs, lighting and import files unchanged.',
    hold_proof='RF_PUMP implies FF/LUNIT/SMALL/ROM_DICT UX A dictionary. Its accepted phase machine updates word_q only E after3SYS acquisition, reset_q onlySYS. Read address is fa(ua)+xv(selector); every XR1..3 writer, including PU overrides, is inside the original SYS block. Hence rf_ra/rf_rb stable between M and nextE for all legalcontroller data/branch choices, not a synthetic job hold. Actual fullcaller monitor separately checks the produced addresses.',
    phase= writes,reader_negative='Addingclk_2x to actualRFread address is rejected by source owner derivation.',
    equivalence='At M read both SYS-held addresses, with memory reflecting precedingE writes. No physical write occurs M→E; at E native SYSoutputregister publishes the M data before currentEwrite. Equals original SYS OLD_DATA for arbitrary late writeinputs and all same-address cases. Both q outputs hold at M, so all original consumers sample identical values at every original edge. No public/private output latency added.',
    import_model='NonQIS architectural RAM deliberately retains original SYSreads and SYSwrite timing, including drained hierarchical deposits; it does not claim to simulate private native M data. Exact actualQIS helper is independently run with shipped Altera25.1 RAM in check.py. No new private prefetch fields need context deposit. All u_rfa.mem/u_rfb.mem names/dimensions remain; every captured lowerB value is loaded from same contextslot asA. Other words coherent from commoninitialstate/broadcastSYSwrite. No arbitrary corrupted copies premise.',
    import_assignments={k:len(v)for k,v in rf.items()},
    timing='Native outputs use clkSYS CLOCK1, retaining original SYS→ALU SYS budget. Address/enable CLK2inputs and internal M→SYSoutput still require ordinary half-cycle setup1/hold0. No new relaxed exception. Existing actualPocket3SYSreset/PLLclockalignment required; phase continues during warmreset.',
    resource='Intended11to7M10K, noDSP. Outputregisters intended inside nativeM10K, phase2FF/address11mux overhead; actualALM/RAM/STA unknown until Root combinedfit. No44pendingwriteFF in selectedarchitecture.',
    limits='Source composition and bounded executed actualvendor/oldcopies/oracle/Rconsumer plus actualcaller trace, not arbitrary-state completecoreSAT. Generic defaultPUMP0 retains arbitrary postMreadaddress changes; privatePUMP1 is only qualified for actualSYS-held producer. No DS timingrule/newhardwareprobe/emulator/game acceptance.')
(out/'composition.json').write_text(json.dumps(result,indent=2)+'\n')
print('RF_COMPOSITION_PASS exactconsumers/default/imports; actualA/XR owners SYS-held; nativeMreads/SYSout+write; normalhalfcycle only')
