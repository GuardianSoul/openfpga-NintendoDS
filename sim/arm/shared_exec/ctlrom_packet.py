#!/usr/bin/env python3
"""Emit actual raw-token/dual-read packet controller used by core and phase miter."""
import pathlib,json
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-ctlrom';S=D/'source';g=(W/'sim/arm/shared_exec/ctlrom_generate.py').read_text();ports=g.split("ports='''",1)[1].split("'''",1)[0];args=['c_ins','h_pc','c_bl2t','f_hw','rl_rem','c_cls','mode_in','rl_r','c_kind','ustep','h_th','h_ab','h_v','qpa','c_bl2','take_fiq','take_irq','hivec'];bind=','.join('.'+x for x in args);lay=json.loads((D/'layout.json').read_text());cr=json.loads((W/'build/cpu232-controller-screen/result.json').read_text());cat=json.loads((D/'catalogue.json').read_text())
s='''// Defaultoff study helper. E token138bits, source-mandated D-only assert metadata43bits.
module arm9_ctlrom_packet #(parameter bit FAULT_TEMPLATE=0)(input logic clk,rst,hold_e,d_go,flush,'''+ports+'''output logic[300:0]d_packet,e_packet,output logic[22:0]seq);
 typedef struct packed{
  logic[31:0]ins;logic[15:0]hw;logic[31:0]pc,bltarget;logic[4:0]mode;
  logic[1:0]step;logic[3:0]listreg;logic[2:0]kind;logic[4:0]cls;
  logic valid,thumb,pcal,highvec;logic[2:0]inject;
 }raw_t;
 raw_t token;
 logic[34:0]ids;logic[42:0]donly,assert_metadata;
 logic[300:0]dshape,eshape;logic[23:0]droute,eroute;
'''
for i,p in enumerate(cat['planes'].values()):s+=f'logic[{p["bits"]-1}:0]d{i},e{i};\n'
s+='ctlrom_address address('+bind+',.ids,.donly,.seq);\n'
s+='arm9_ctlrom_planes #(.FAULT_TEMPLATE(FAULT_TEMPLATE)) banks(.clk,.rst,.hold_e,.ids,'+','.join('.d'+str(i)+',.e'+str(i)for i in range(6))+');\n'
s+="always_comb begin dshape='0;eshape='0;\n"
for i,group in enumerate(cr['planes'].values()):
 for f in group['field_layout']:
  s+=f"dshape[{f['source_offset']}+:{f['width']}]=d{i}[{f['plane_offset']}+:{f['width']}];\n"
  s+=f"eshape[{f['source_offset']}+:{f['width']}]=e{i}[{f['plane_offset']}+:{f['width']}];\n"
for i,b in enumerate(lay['donly']):s+=f'dshape[{b}]=donly[{i}];eshape[{b}]=assert_metadata[{i}];\n'
s+=f"dshape[{lay['layout']['valid'][0]}]=h_v;eshape[{lay['layout']['valid'][0]}]=token.valid;end\nassign droute={{d5,d4}};assign eroute={{e5,e4}};\n"
s+='ctlrom_reconstruct d_reconstruct('+bind+',.shape(dshape),.route(droute),.packet(d_packet));\n'
eb={'c_ins':'token.ins','h_pc':'token.pc','c_bl2t':'token.bltarget','f_hw':'token.hw','rl_rem':"16'd0",'c_cls':'token.cls','mode_in':'token.mode','rl_r':'token.listreg','c_kind':'token.kind','ustep':'token.step','h_th':'token.thumb','h_ab':"(token.inject==3'd1)",'h_v':'token.valid','qpa':'token.pcal','c_bl2':"1'b0",'take_fiq':"(token.inject==3'd2)",'take_irq':"(token.inject==3'd3)",'hivec':'token.highvec'}
s+='ctlrom_reconstruct e_reconstruct('+','.join('.'+n+'('+v+')'for n,v in eb.items())+',.shape(eshape),.route(eroute),.packet(e_packet));\n'
s+='''always_ff @(posedge clk)begin
 if(rst)begin token<='0;assert_metadata<=0;end
 else begin
  if(!hold_e)begin
   token.ins<=c_ins;token.hw<=f_hw;token.pc<=h_pc;token.bltarget<=c_bl2t;token.mode<=mode_in;
   token.step<=ustep;token.listreg<=rl_r;token.kind<=c_kind;token.cls<=c_cls;
   token.valid<=h_v&&d_go;token.thumb<=h_th;token.pcal<=qpa;token.highvec<=hivec;
   token.inject<=h_ab?3'd1:take_fiq?3'd2:take_irq?3'd3:3'd0;
   assert_metadata<=donly;
  end
  if(flush)token.valid<=0;
 end
end
`ifndef SYNTHESIS
 initial if($bits(raw_t)!=138)$fatal(1,"raw context token width changed");
`endif
endmodule
''';(S/'arm9_ctlrom_packet.sv').write_text(s)
# Clocked phase harness. Owned decode values only change on SYS, by construction
# matching their source FF owners. External highvec, stall/flush/dgo and reset
# remain unconstrained on every half-cycle; late changes are never assumed away.
phaseports=ports.replace('input logic','input logic').replace('c_ins,h_pc,c_bl2t','next_c_ins,next_h_pc,next_c_bl2t').replace('f_hw,rl_rem','next_f_hw,next_rl_rem').replace('c_cls,mode_in','next_c_cls,next_mode_in').replace('rl_r,','next_rl_r,').replace('c_kind,','next_c_kind,').replace('ustep,','next_ustep,')
phaseports=phaseports.replace('h_th,h_ab,h_v,qpa,c_bl2,take_fiq,take_irq,hivec','next_h_th,next_h_ab,next_h_v,next_qpa,next_c_bl2,next_take_fiq,next_take_irq,hivec')
h='module ctlrom_phase_miter #(parameter bit FAULT_TEMPLATE=0)(input logic clk,rst,hold_e,d_go,flush,'+phaseports+'output logic bad);\n'
for n,w in [('c_ins',32),('h_pc',32),('c_bl2t',32),('f_hw',16),('rl_rem',16),('c_cls',5),('mode_in',5),('rl_r',4),('c_kind',3),('ustep',2),('h_th',1),('h_ab',1),('h_v',1),('qpa',1),('c_bl2',1),('take_fiq',1),('take_irq',1)]:h+='logic'+(''if w==1 else'['+str(w-1)+':0]')+' '+n+';\n'
h+='always_ff @(posedge clk)begin\n'
for n in args:
 if n!='hivec':h+=n+'<=rst?0:next_'+n+';\n'
h+='end\nlogic[300:0]ref_d,ref_e,new_d,new_e;logic bad_d;\n'
h+='ctlrom_decode_before original('+bind+',.packet(ref_d),.route(),.seq());\n'
h+='arm9_ctlrom_packet #(.FAULT_TEMPLATE(FAULT_TEMPLATE)) candidate(.clk,.rst,.hold_e,.d_go,.flush,'+bind+',.d_packet(new_d),.e_packet(new_e),.seq());\n'
h+=f'''always_ff @(posedge clk)begin
 if(rst)begin ref_e<=0;bad_d<=0;end
 else begin
  bad_d<=new_d!=ref_d;
  if(!hold_e)begin ref_e<=ref_d;if(!d_go)ref_e[{lay['layout']['valid'][0]}]<=0;end
  if(flush)ref_e[{lay['layout']['valid'][0]}]<=0;
 end
end
assign bad=(new_e!=ref_e)||bad_d;
endmodule
''';(S/'ctlrom_phase_miter.sv').write_text(h)
print('actual packet controller + clocked phase miter emitted')
