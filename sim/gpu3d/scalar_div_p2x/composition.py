#!/usr/bin/env python3
"""Exact inverse and unchanged scope for the new scalar context only."""
import hashlib
import json
import subprocess
from pathlib import Path

R=Path(__file__).resolve().parents[3];B=R/'build/geometry-scalar-div14'
BASE='f0bbdcd12ec35493376de90030439496ca32856a'
edits={
 'rtl/gpu3d/gpu3d_gxeng.sv':[
  ("    parameter int DIVK = 4,\n    parameter bit SCALAR_DIV_P2X = 1'b0 // scalar u_div only, independent of clip/finalize\n","    parameter int DIVK = 4\n"),
  (", .K4_P2X(SCALAR_DIV_P2X && PU)",""),
 ],
 'rtl/gpu3d/gpu3d_geom.sv':[
  ("    parameter bit SP_SIM = 1'b0,       // tests (tb_geom): a behavioural SDRAM on the sp_* ports, with varying latency\n    parameter bit GX_SCALAR_DIV_P2X = 1'b0 // scalar u_eng.u_div only; existing clip/finish option is independent\n","    parameter bit SP_SIM = 1'b0        // tests (tb_geom): a behavioural SDRAM on the sp_* ports, with varying latency\n"),
  (", .SCALAR_DIV_P2X(GX_SCALAR_DIV_P2X)",""),
 ],
 'rtl/gpu3d/gpu3d_gxdiv.sv':[
  ("    parameter int K = 0,\n    parameter bit K4_P2X = 1'b0 // one scalar K4 context; retain its SYS quotient publication\n","    parameter int K = 0\n"),
  ("    parameter int NUM_MODE = 0,\n    parameter bit SYS_Q = 1'b0 // scalar caller reads partial quotients: publish only at SYS\n","    parameter int NUM_MODE = 0\n"),
  ('''    generate if (K4_P2X && K == 4) begin : g_k4_pump
        gpu3d_gxdivk #(.K(4), .P2X(1'b1), .SYS_Q(1'b1)) u_fast (
            .clk, .clk2, .rst, .start, .qb, .num, .den, .preload(1'b0), .busy, .q);
`ifndef ALTERA_RESERVED_QIS
        assign dbg_cnt = u_fast.g_p2.cnt;
`else
        assign dbg_cnt = 7'd0; // private simulation profiler only
`endif
    end else if (K > 1) begin : g_k
''',"    generate if (K > 1) begin : g_k\n"),
  ('''        if (SYS_Q) begin : g_sys_q
            // M has performed the first half. q_n is what E completes,
            // before the next SYS consumer can select XS_Q. Reset holds
            // the previous SYS value exactly as the original K divider.
            always_ff @(posedge clk) begin
                if (!rst) begin
                    if (start) q <= 32'd0;
                    else if (busy) q <= rsm ? 32'd0 : q_n;
                end
            end
        end else begin : g_fast_q
            assign q = q2;
        end
''',"        assign q = q2;\n"),
 ],
}
changed=subprocess.check_output(['git','diff',BASE,'--name-only','--','rtl','scripts','tools/gxasm'],cwd=R,text=True).splitlines()
assert set(changed)==set(edits),changed
hashes={}
for path,replacements in edits.items():
    data=(R/path).read_bytes();text=data.decode()
    for new,old in replacements:
        assert text.count(new)==1,(path,new);text=text.replace(new,old)
    before=subprocess.check_output(['git','show',BASE+':'+path],cwd=R)
    assert text.encode()==before,path
    hashes[path]={'before_sha256':hashlib.sha256(before).hexdigest(),'candidate_sha256':hashlib.sha256(data).hexdigest()}
record={'before':BASE,'exact_inverse':hashes,'unchanged_scope':'Entire existing divider steps/restart/busy machinery, NUM_MODE/preload/cohort ports and code; clip/finalize/front/RAM/ROM/microcode/public Pocket wiring and strict gxdivk SDC unchanged. Four appended flags default0; K4_P2X ignored unlessK4, only PU scalar caller selects it.','limits':'Source inverse only; new actual-before/caller/service/mutation and enabled build remain separate required checks.'}
B.mkdir(parents=True,exist_ok=True);(B/'composition.json').write_text(json.dumps(record,indent=2)+'\n')
print('PASS exact three-file inverse; all other production/SDC/microcode unchanged')
