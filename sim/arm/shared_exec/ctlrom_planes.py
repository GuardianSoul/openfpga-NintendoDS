#!/usr/bin/env python3
"""Emit actual six dual-read banks and combinational formal table model."""
import pathlib,json
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-ctlrom';S=D/'source';r=json.loads((D/'catalogue.json').read_text());a=json.loads((D/'address-result.json').read_text());assert r['status']=='SIX_PLANE_CAPACITY_PASS';iw=a['plane_ID_bits'];n=sum(iw)
ports=','.join(f'output logic[{p["bits"]-1}:0]p{i}'for i,p in enumerate(r['planes'].values()))
s=f'module ctlrom_lut_comb(input logic[{n-1}:0]ids,{ports});\n';off=0
for i,p in enumerate(r['planes'].values()):
 w=p['bits'];s+=f'always_comb begin p{i}=0;case(ids[{off}+:{iw[i]}])\n'
 for j,v in enumerate(p['words']):s+=f"{iw[i]}'d{j}:p{i}={w}'h{v:x};\n"
 s+='default:;endcase end\n';off+=iw[i]
s+='endmodule\n';(S/'ctlrom_lut_comb.sv').write_text(s)
ports=','.join(f'output logic[{p["bits"]-1}:0]d{i},e{i}'for i,p in enumerate(r['planes'].values()))
s=f'''// Six independent two-read ROM banks. Original SYS phases, no native service queue.
module arm9_ctlrom_planes #(parameter bit FAULT_TEMPLATE=0)(input logic clk,rst,hold_e,input logic[{n-1}:0]ids,{ports});
''';off=0
for i,p in enumerate(r['planes'].values()):
 w=p['bits'];s+=f'(* ramstyle="M10K" *) logic[{w-1}:0]rom{i}[0:511];\ninitial begin\n for(integer k=0;k<512;k++)rom{i}[k]=0;\n'
 for j,v in enumerate(p['words']):s+=f" rom{i}[{j}]={w}'h{v:x};\n"
 s+='end\n';s+=f'always_ff @(negedge clk)d{i}<=rom{i}[ids[{off}+:{iw[i]}]];\n'
 idstr=f'ids[{off}+:{iw[i]}]'+(" ^ 8'(FAULT_TEMPLATE)"if i==0 else'')
 s+=f"always_ff @(posedge clk)if(rst||!hold_e)e{i}<=rom{i}[rst?{iw[i]}'d0:({idstr})];\n";off+=iw[i]
s+='endmodule\n';(S/'arm9_ctlrom_planes.sv').write_text(s)
# Replace the provisional semantic shape in the miter with actual lowered IDs
# and exact table outputs. Original raw-input reference remains unchanged.
g=(W/'sim/arm/shared_exec/ctlrom_generate.py').read_text();rawports=g.split("ports='''",1)[1].split("'''",1)[0];args=['c_ins','h_pc','c_bl2t','f_hw','rl_rem','c_cls','mode_in','rl_r','c_kind','ustep','h_th','h_ab','h_v','qpa','c_bl2','take_fiq','take_irq','hivec'];bind=','.join('.'+x for x in args)
lay=json.loads((D/'layout.json').read_text());cr=json.loads((W/'build/cpu232-controller-screen/result.json').read_text());m='module ctlrom_actual_miter('+rawports+'output logic bad);\nlogic[300:0]oldp,newp,shape;logic[23:0]route;logic[34:0]ids;logic[42:0]donly;logic[22:0]seq,oldseq;\n'
for i,p in enumerate(r['planes'].values()):m+=f'logic[{p["bits"]-1}:0]p{i};\n'
m+='ctlrom_decode_before oldd('+bind+',.packet(oldp),.route(),.seq(oldseq));\n'
m+='ctlrom_address address('+bind+',.ids,.donly,.seq);\nctlrom_lut_comb tables(.ids,.p0,.p1,.p2,.p3,.p4,.p5);\n'
m+="always_comb begin shape='0;\n"
for i,group in enumerate(cr['planes'].values()):
 for f in group['field_layout']:m+=f"shape[{f['source_offset']}+:{f['width']}]=p{i}[{f['plane_offset']}+:{f['width']}];\n"
for i,b in enumerate(lay['donly']):m+=f'shape[{b}]=donly[{i}];\n'
m+=f"shape[{lay['layout']['valid'][0]}]=h_v;end\nassign route={{p5,p4}};\n"
m+='ctlrom_reconstruct rebuild('+bind+',.shape,.route,.packet(newp));\nassign bad=(oldp!=newp)||(oldseq!=seq);\nendmodule\n';(S/'ctlrom_actual_miter.sv').write_text(m)
print('emitted actual banks, table model and lowered-ID full301bit miter')
