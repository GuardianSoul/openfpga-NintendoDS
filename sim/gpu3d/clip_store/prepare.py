#!/usr/bin/env python3
"""Prepare only the new store's affected clip/caller relation to literal976."""
import json
import re
import subprocess
from pathlib import Path

R=Path(__file__).resolve().parents[3];B=R/'build/geometry-clip-pump16'
BASE='97698ee421304616961056481a9353b9a9a10538';B.mkdir(parents=True,exist_ok=True)
def old(leaf):return subprocess.check_output(['git','show',BASE+':rtl/gpu3d/gpu3d_'+leaf+'.sv'],cwd=R,text=True)
def module(text,name):return re.search(r'(?ms)^module\s+'+name+r'\b.*?^endmodule\b[^\n]*',text)[0]+'\n'
clip=module(old('gxvfin'),'gpu3d_gxclip').replace('module gpu3d_gxclip #','module gpu3d_gxclip_before #',1)
(B/'before-clip.sv').write_text(clip)
eng=module(old('gxeng'),'gpu3d_gxeng').replace('module gpu3d_gxeng #','module gpu3d_gxeng_before #',1).replace('gpu3d_gxclip #','gpu3d_gxclip_before #')
(B/'before-eng.sv').write_text(eng)
geom=module(old('geom'),'gpu3d_geom').replace('module gpu3d_geom #','module gpu3d_geom_before #',1).replace('gpu3d_gxeng #','gpu3d_gxeng_before #')
(B/'before-geom.sv').write_text(geom)
pkg=(R/'rtl/gpu3d/gpu3d_gxu_pkg.sv').read_text()
constants={n:int(v,16)for n,v in re.findall(r"localparam logic \[10:0\] (\w+) = 11'h([0-9A-Fa-f]+)",pkg)}
(B/'addresses.h').write_text('\n'.join(f'constexpr unsigned {n}=0x{v:x};'for n,v in constants.items())+'\n')
outputs={'cond':1,'cw':1,'cwa':11,'cwd':32,'busy':1,'nnew':4,'nside':1,'nnew_v':1}
top=['''module tb_clip_store #(parameter bit RED=1,parameter bit MUTANT=0)(
input logic clk,clk2,rst,we,run,can,wfree,input logic [10:0] wa,input logic [31:0] wd,
output wire cond,cw,busy,nnew_v,output wire [10:0] cwa,output wire [31:0] cwd,
output wire [3:0] nnew,output wire nside,
output wire [17:0] read_valid,output wire [8:0] read_addr[18],
output logic [31:0] old_data_collisions,neighbour_reads,head_reads,colour_reads,
output logic [31:0] full_clocks,held_clocks,rf_takes,outcomes);
import gpu3d_gxu_pkg::*;''']
params='.A_LA(FU_A_LA),.A_LN(FU_A_LN),.A_CS(FU_A_CS),.A_OCM(PU_A_OCM),.A_CATTR(LU_A_CATTR),.A_POOL(PU_A_POOL),.DS_CLIPRED(RED),.DIV_P2X(1),.COHORT(1)'
for tag,name in [('a','gpu3d_gxclip_before'),('b','gpu3d_gxclip')]:
 for n,w in outputs.items():top.append(f'wire [{w-1}:0] {n}_{tag};')
 con=[f'.{n}({n})'for n in ['clk','clk2','rst','we','wa','wd','run','can','wfree']]+[f'.{n}({n}_{tag})'for n in outputs]
 top.append(f'{name} #({params}'+(', .STORE_PUMP(1)'if tag=='b'else'')+f') {tag}('+','.join(con)+');')
for n in outputs:top.append(f'assign {n}={n}_a;')
top.append('''logic [31:0] written=0;
always @(posedge clk) if(!rst&&a.pu)written[a.qw[4:0]]<=1;
assign read_valid=a.st==a.S_HT&&a.li<a.ln ? (18'd1<<3)|(18'd1<<a.comp) :
 a.st==a.S_NB&&a.nk==9&&a.rk==0 ? 18'h3ffff :
 a.st==a.S_CM&&a.qe&&!a.pu&&a.k<a.ln ? 18'h70 : 18'd0;
genvar rp;generate for(rp=0;rp<18;rp++)begin:g_probe
 assign read_addr[rp]={(rp<9?a.rgroup_out:a.rgroup_in),4'(rp%9<7?rp%9:rp%9+1)};
end endgenerate
// Both read views need agree when the original SYS consumer takes them.
// Raw FAST intermediate outputs are deliberately not compared after E.
always @(posedge clk)if(!rst&&!MUTANT)begin
 if(a.st==a.S_HT2 && (a.outside_word[3]!==b.outside_word[3] || a.outside_word[a.comp]!==b.outside_word[a.comp]))$fatal(1,"clip consumed head mismatch");
 if(a.st==a.S_NB2)for(int i=0;i<9;i++)if(a.outside_word[i]!==b.outside_word[i]||a.inside_word[i]!==b.inside_word[i])$fatal(1,"clip consumed neighbour mismatch field%0d",i);
 if(a.st==a.S_CM2)for(int i=0;i<3;i++)if(a.outside_word[i+4]!==b.outside_word[i+4])$fatal(1,"clip consumed colour mismatch");
end
always @(negedge clk)if(!rst)begin
 if(cw_a&&cwd_a!==cwd_b)$fatal(1,"CLIP_PUBLIC_CWD_MISMATCH old%08x new%08x",cwd_a,cwd_b);
''')
for n in outputs:
 gate='cw_a'if n in ['cwa','cwd']else'nnew_v_a'if n in ['nnew','nside']else'1'
 top.append(f'if({gate}&&{n}_a!=={n}_b)$fatal(1,"clip public {n} mismatch");')
top.append('if(!MUTANT)begin')
for n in ['st','done','cur','ln','li','lcnt','cs','ocm','far12','newv','pool0','pool','hx','side','v','u','vw','vc','num','den','k','pts','rv','ru','dgo','dwait','qw','qr','nk','rk','nva','ck']:
 top.append(f'if(a.{n}!==b.{n})$fatal(1,"clip retained {n} mismatch");')
top.append('''for(int i=0;i<10;i++)if(a.sn_la[i]!==b.sn_la[i]||a.la[i]!==b.la[i]||a.lb[i]!==b.lb[i])$fatal(1,"clip list mismatch");
for(int i=0;i<9;i++)if(a.vin[i]!==b.vin[i]||a.nv[i]!==b.nv[i])$fatal(1,"clip consumed arithmetic latch mismatch");
for(int i=0;i<3;i++)if(a.cm[i]!==b.cm[i])$fatal(1,"clip retained CM mismatch");
for(int i=0;i<32;i++)if(written[i]&&a.u_write_queue.mem[i]!==b.u_write_queue.mem[i])$fatal(1,"clip retained queue mismatch");
end end
logic [17:0] collision;
always_comb for(int i=0;i<18;i++)collision[i]=we&&wa[10:9]==2'b01&&read_valid[i]&&wa[8:0]==read_addr[i];
always @(posedge clk)if(rst)begin old_data_collisions<=0;neighbour_reads<=0;head_reads<=0;colour_reads<=0;full_clocks<=0;held_clocks<=0;rf_takes<=0;outcomes<=0;end else begin
 old_data_collisions<=old_data_collisions+32'(|collision);neighbour_reads<=neighbour_reads+32'(a.st==a.S_NB2);
 head_reads<=head_reads+32'(a.st==a.S_HT2);colour_reads<=colour_reads+32'(a.st==a.S_CM2);
 full_clocks<=full_clocks+32'(a.qfull);held_clocks<=held_clocks+32'(cw_a&&!wfree);rf_takes<=rf_takes+32'(cw_a&&wfree);outcomes<=outcomes+32'(nnew_v_a);
end
endmodule''')
(B/'clip.sv').write_text('\n'.join(top)+'\n')
driver=(R/'sim/gpu3d/divider_pump/clip.cpp').read_text().replace('Vtb_clip_wordbanks','Vtb_clip_store')
(R/'sim/gpu3d/clip_store/clip.cpp').write_text(driver)

# Fresh complete caller relation, same immutable976 on the control side.
old_prepare=(R/'sim/gpu3d/scalar_div_p2x/prepare.py').read_text()
section=old_prepare[old_prepare.index('outputs={'):old_prepare.index("(B/'prepare.json')")]
# Use its wrapper construction without its old scalar before-source setup.
section=section.replace("params+=',.GX_SCALAR_DIV_P2X(1)'","params+=',.GX_CLIP_STORE_PUMP(1)'")
section=section.replace('.ENG_M10K(0),.SPILL', '.ENG_M10K(0),.GX_SCALAR_DIV_P2X(1),.SPILL')
section=section.replace("R/'sim/gpu3d/scalar_div_p2x/caller.cpp'","R/'sim/gpu3d/clip_store/caller.cpp'")
exec(compile(section,'scalar stimulus construction','exec'),{'R':R,'B':B})
(B/'prepare.json').write_text(json.dumps({'before':BASE,'scope':'New5latefieldstore actualbefore clip/native/caller, all scalar/math/front logic retained'},indent=2)+'\n')
print('Prepared new late-store relation to literal976; no compiler launched')
