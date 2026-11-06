#!/usr/bin/env python3
"""Prepare the new scalar context fixtures without starting a heavy worker."""
import json
import re
import subprocess
from pathlib import Path

R=Path(__file__).resolve().parents[3]
B=R/'build/geometry-scalar-div14'
BASE='f0bbdcd12ec35493376de90030439496ca32856a'
B.mkdir(parents=True,exist_ok=True)

def get(leaf):
    return subprocess.check_output(['git','show',BASE+':rtl/gpu3d/gpu3d_'+leaf+'.sv'],cwd=R,text=True)

def one(text,name):
    return re.search(r'(?ms)^module\s+'+name+r'\b.*?^endmodule\b[^\n]*',text)[0]+'\n'

olddiv=get('gxdiv')
for name in ['gpu3d_gxdivk','gpu3d_gxclip_cohort','gpu3d_gxdiv']:
    olddiv=re.sub(r'\b'+name+r'\b',name+'_before',olddiv)
(B/'before-div.sv').write_text(olddiv)
oldeng=one(get('gxeng'),'gpu3d_gxeng')
oldeng=re.sub(r'\bgpu3d_gxeng\b','gpu3d_gxeng_before',oldeng)
oldeng=re.sub(r'\bgpu3d_gxdiv\b','gpu3d_gxdiv_before',oldeng)
(B/'before-eng.sv').write_text(oldeng)
oldgeom=get('geom').replace('module gpu3d_geom #','module gpu3d_geom_before #').replace('gpu3d_gxeng #','gpu3d_gxeng_before #')
(B/'before-geom.sv').write_text(oldgeom)
(B/'unit.sv').write_text('''module tb_scalar_divider(input logic clk,clk2,rst,start,input logic [1:0] qb,input logic [63:0] num,input logic [31:0] den,output wire busy,output wire [31:0] q,output logic [31:0] sys_checks=0,mid_checks=0);
wire ob;wire [31:0] oq;
gpu3d_gxdiv_before #(.K(4),.P2X(1)) a(.clk,.clk2,.rst,.start,.qb,.num,.den,.busy(ob),.q(oq));
gpu3d_gxdiv #(.K(4),.K4_P2X(1)) b(.clk,.clk2,.rst,.start,.qb,.num,.den,.busy,.q);
logic known=0;
always @(posedge clk) if(!rst && start) known<=1;
always @(negedge clk) begin
 if(busy!==ob) $fatal(1,"scalar SYS busy mismatch");
 if(known && q!==oq) $fatal(1,"scalar SYS q mismatch");
 sys_checks<=sys_checks+1;
end
always @(negedge clk2) if(!clk && known) begin
 if(q!==oq) $fatal(1,"scalar MID q hold mismatch");
 mid_checks<=mid_checks+1;
end
endmodule
''')

# Reuse only the existing stimulus recipe. The new relation compares actual
# f0bb before-source with the newly selected scalar context on both sides.
outputs={'io_rdata':32,'io_ack':1,'io_wait':1,'irq_gxfifo':1,'dma_gx_low':1,'gx_stall':1,'ovf_set':1,'po_valid':1,'po_type':1,'po_data':128,'po_index':11,'po_wv':1,'po_wk':2,'po_wd':32,'so_we':1,'so_pos':11,'so_idx':11,'so_done':1,'so_count':12,'dbg_stall':1,'dbg_apply':1,'dbg_upc':11,'dbg_flush':1,'dbg_idle':1,'dbg_gxstat':32,'dbg_npoly':12,'dbg_nvert':13,'diag_ev':3,'diag_used':13,'dbg_eq_bad':1}
top=['''module tb_scalar_caller(input logic clk,clk_2x,rst,tick,vblank,io_req,io_we,po_ready,input logic [7:0] io_addr,input logic [31:0] io_wdata,
output wire io_wait,io_ack,dbg_flush,dbg_idle,po_valid,po_type,output wire [31:0] io_rdata,
output logic [31:0] outcomes,late_clocks,clip_starts,fin_starts,rf_writes,headers,vertices,irq_clocks,dma_clocks,held_beats,
output logic [31:0] div_starts=0,selected_q=0,busy_checks=0);
import gpu3d_gxu_pkg::*;''']
for suffix,module in [('a','gpu3d_geom_before'),('b','gpu3d_geom')]:
    for n,w in outputs.items():top.append(f'wire [{w-1}:0] {n}_{suffix};')
    params=".FF(1),.LUNIT(1),.VFIN(2),.USORT(1),.GX_DSX(1),.GX_SWAP_OVERLAP(1),.GX_L44_READ(1),.GX_MAT_PAR(1),.GX_DIV_P2X(1),.GX_ROM_DICT(1),.ENG_M10K(0),.SPILL(1),.SP_SIM(1),.SP_ON(4096),.SP_AW(18)"
    if suffix=='b':params+=',.GX_SCALAR_DIV_P2X(1)'
    con=[f'.{n}({n})'for n in ['clk','clk_2x','rst','tick','vblank','io_req','io_we','io_addr','io_wdata','po_ready']]
    con += [f'.{n}({n}_{suffix})'for n in outputs]
    con += [".geom_en(1'b1)",".io_be(4'hF)",".io_wpre(21'd0)",".s_draw(1'b0)",".sp_wack(1'b0)",".sp_wdrained(1'b1)",".sp_rack(1'b0)",".sp_rvalid(1'b0)",".sp_rdata(32'd0)"]
    top.append(f'{module} #({params}) {suffix}('+','.join(con)+');')
for n in ['io_wait','io_ack','dbg_flush','dbg_idle','po_valid','po_type','io_rdata']:top.append(f'assign {n}={n}_a;')
top.append('always @(negedge clk) if(!rst) begin')
# Check the consumed quotient first so a real retention-phase fault is
# attributed to the caller rather than a later pipeline/public mismatch.
top.append('''if(a.u_eng.od.xs[XS_Q] && a.u_eng.div_q!==b.u_eng.div_q)
 $fatal(1,"actual scalar caller selected XS_Q mismatch");
if(a.u_eng.div_busy!==b.u_eng.div_busy) $fatal(1,"actual scalar caller busy mismatch");''')
for n in outputs:
    gate='1'
    if n=='io_rdata':gate='io_ack_a && !io_we'
    if n in ['po_type','po_data','po_index']:gate='po_valid_a'
    if n in ['po_wk','po_wd']:gate='po_wv_a'
    if n in ['so_pos','so_idx']:gate='so_we_a'
    if n=='so_count':gate='so_done_a'
    top.append(f'if({gate} && {n}_a!=={n}_b) $fatal(1,"scalar caller {n} mismatch");')
top.append('''if(a.u_eng.rf_we!==b.u_eng.rf_we || a.u_eng.rf_we && (a.u_eng.rf_wa!==b.u_eng.rf_wa || a.u_eng.rf_wd!==b.u_eng.rf_wd)) $fatal(1,"scalar caller RF/order mismatch");
if(a.oc_valid!==b.oc_valid || a.u_front.stand!==b.u_front.stand) $fatal(1,"scalar caller outcome/debt mismatch");
if(a.oc_valid && {a.oc_rej,a.oc_quad,a.oc_side,a.oc_nv,a.oc_ncl}!=={b.oc_rej,b.oc_quad,b.oc_side,b.oc_nv,b.oc_ncl}) $fatal(1,"scalar caller outcome payload mismatch");
end
always @(posedge clk) if(rst) begin
outcomes<=0;late_clocks<=0;clip_starts<=0;fin_starts<=0;rf_writes<=0;headers<=0;vertices<=0;irq_clocks<=0;dma_clocks<=0;held_beats<=0;
end else begin
div_starts<=div_starts+32'(a.u_eng.b_div!=DIV_NONE);selected_q<=selected_q+32'(a.u_eng.od.xs[XS_Q]);busy_checks<=busy_checks+1;
outcomes<=outcomes+32'(a.oc_valid);late_clocks<=late_clocks+32'(a.u_front.stand);
clip_starts<=clip_starts+32'(a.u_eng.g_cl.u_clip.dgo);fin_starts<=fin_starts+32'(a.u_eng.g_fu.u_fin.dstart);
rf_writes<=rf_writes+32'(a.u_eng.rf_we);headers<=headers+32'(po_valid_a&&po_ready&&!po_type_a);vertices<=vertices+32'(po_valid_a&&po_ready&&po_type_a);
irq_clocks<=irq_clocks+32'(irq_gxfifo_a);dma_clocks<=dma_clocks+32'(dma_gx_low_a);held_beats<=held_beats+32'(po_valid_a&&!po_ready);
end
endmodule''')
(B/'caller.sv').write_text('\n'.join(top)+'\n')
cpp=(R/'sim/gpu3d/divider_pump/coupled.cpp').read_text().replace('Vtb_coupled_pump','Vtb_scalar_caller')
needle='''        // Exercise the accepted busy-tail read boundary'''
assert cpp.count(needle)==1
cpp=cpp.replace(needle,'''        // BOX_TEST crossing side planes exercises the main scalar clip routines.
        for(unsigned box=0;box<8;++box){
            cmd(0x70,{0xf800e000U+box*17,0x4000f800U,0x10004000U});read(0x600);
        }
'''+needle)
cpp=cpp.replace('    d.final();','''    std::printf("scalar starts=%u selectedXS_Q=%u busychecks=%u\\n",d.div_starts,d.selected_q,d.busy_checks);
    if(!d.div_starts || !d.selected_q)throw std::runtime_error("new scalar context not exercised");
    d.final();''')
(R/'sim/gpu3d/scalar_div_p2x/caller.cpp').write_text(cpp)
(B/'prepare.json').write_text(json.dumps({'before':BASE,'scope':'New scalar K4/SYS quotient seam; complete caller before pair; no accepted primitive/clip/finalize rerun'},indent=2)+'\n')
print('Prepared source fixtures only; no compiler/model launched')
