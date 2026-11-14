#!/usr/bin/env python3
"""Extract exact D semantics, attach route provenance, and emit reconstruction miter."""
import pathlib,subprocess,re,json
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-ctlrom';D.mkdir(exist_ok=True);S=D/'source';S.mkdir(exist_ok=True)
s=subprocess.check_output(['git','show','232c26ac:rtl/arm/arm9_core.sv'],cwd=W,text=True)
const=s[s.index('  localparam logic [2:0] TK_ARM'):s.index('  // One uop')]
typ=s[s.index('  typedef struct packed {'):s.index('  // ---------------------------------------------------------------- state')]
helpers=s[s.index('  function automatic logic [4:0] popcnt16'):s.index('  assign a_cls =',s.index('  function automatic logic [4:0] popcnt16'))]
a=s.index('  always_comb begin\n    logic [4:0] bank_ra');b=s.index('  // The instruction has more uops',a);block=s[a:b]
ports='''input logic[31:0]c_ins,h_pc,c_bl2t,
 input logic[15:0]f_hw,rl_rem,
 input logic[4:0]c_cls,mode_in,
 input logic[3:0]rl_r,
 input logic[2:0]c_kind,
 input logic[1:0]ustep,
 input logic h_th,h_ab,h_v,qpa,c_bl2,take_fiq,take_irq,hivec,
'''
setup='''logic[31:0]cpsr,c_tgt;logic[1:0]hivecs;logic[0:0]q_pa;
assign cpsr={27'd0,mode_in};assign hivecs={1'b0,hivec};assign q_pa={qpa};
logic more;logic[1:0]nstep;logic[15:0]nrl;logic[3:0]nrl_r;
assign nrl_r = (ustep == 2'd0) ? ((c_ins[15:0] == 16'h0) ? 4'd15 : lowest16(c_ins[15:0])) :
                 (rl_rem == 16'h8000) ? 4'd15 : lowest16(rl_rem & ~(16'h1 << rl_r));
always_comb begin
 logic[31:0]off;
 if(h_th)begin
  if(f_hw[15:11]==5'b11100)off={{20{f_hw[10]}},f_hw[10:0],1'b0};
  else if(f_hw[15:11]==5'b11110)off={{9{f_hw[10]}},f_hw[10:0],12'b0};
  else off={{23{f_hw[7]}},f_hw[7:0],1'b0};
 end else off={{6{c_ins[23]}},c_ins[23:0],(c_ins[31:25]==7'b1111101)&c_ins[24],1'b0};
 c_tgt=h_pc+(h_th?32'd4:32'd8)+off;
end
uop9_t u,u0;
'''
header='module ctlrom_decode import arm_pkg::*; ('+ports+'output logic[300:0]packet,output logic[23:0]route,output logic[22:0]seq);\n'+const+typ+helpers+setup
# Route provenance, updated at original assignments, never inferred by data equality.
# layout: imm4/link3/pcv2/pcvc1/cond2/wa3/bank2/msr1/cp1/excmode5.
imm={"{24'h0, ins[7:0]}":1,"{24'h0, ins[11:8], ins[3:0]}":2,"{20'h0, ins[11:0]}":3,"{25'h0, cnt, 2'b00}":4,'c_tgt':5,"{20'h0, ins[10:0], 1'b0}":6,'c_bl2t':7,"(hivecs[0] ? 32'hFFFF0000 : 32'h0) + evec":8}
link={'link4':1,'c_tgt':2,"link4 | 32'h1":3,"h_th ? (link4 | 32'h1) : link4":4,"h_pc + 32'd4":5}
wa={"5'(rd)":1,"5'(rn)":2,"5'((ustep == 2'd1) ? rd : {rd[3:1], 1'b1})":3,"5'(r)":4,"5'(4'hE)":5}
def tag(m):
 field=m[1];rhs=m[2].strip();code=''
 if field=='imm':code=f"route[3:0]=4'd{imm[rhs]};"
 elif field=='link':code=f"route[6:4]=3'd{link[rhs]};"
 elif field=='pcv':code="route[8:7]=2'd"+('1'if rhs.startswith('q_pa')else'2')+';'
 elif field=='pcv_c':code="route[9]=1'b1;"
 elif field=='cond':code="route[11:10]=2'd"+({'ins[31:28]':'1',"4'hE":'2',"4'hF":'3'}[rhs])+';'
 elif field=='wa'and rhs=="phys_reg(4'hE, emode)":code="route[14:12]=3'd5;route[16:15]=2'd2;"
 elif field=='wa'and not rhs.startswith('phys_reg'):code=f"route[14:12]=3'd{wa[rhs]};"
 elif field=='msr_mask':code="route[17]=1'b1;"
 elif field=='cp_op':code="route[18]=1'b1;"
 elif field=='exc_mode':code='route[23:19]=emode;'
 return ('begin '+m[0]+code+' end')if code else m[0]
# RHS semicolons delimit all scalar data assignments in the original block.
t=block.replace("u = '0;","u = '0;route='0;")
t=re.sub(r'u\.(imm|link|pcv_c|pcv|cond|wa|msr_mask|cp_op|exc_mode)\s*=\s*([^;]+);',tag,t)
def banktag(m):
 rhs=m[1].strip();code={'M_USR':"2'd0",'mode':"2'd1",'emode':"2'd2",'bmode':"(ubank?2'd0:2'd1)"}[rhs];return 'begin '+m[0]+'route[16:15]='+code+'; end'
t=re.sub(r'bank_wa\s*=\s*([^;]+);',banktag,t)
# The descriptor carries the original computed list cursor. All other data
# sources are reconstructed from raw inputs, including live high-vector.
(S/'ctlrom_decode.sv').write_text(header+t+'assign packet=u;assign seq={more,nstep,nrl,nrl_r};\nendmodule\n')
# Keep reference pure D packet independently byte-bound, with no routing tags.
(S/'ctlrom_decode_before.sv').write_text(header.replace('module ctlrom_decode ','module ctlrom_decode_before ')+block+"assign packet=u;assign route=0;assign seq={more,nstep,nrl,nrl_r};\nendmodule\n")
fields=[]
for line in typ.splitlines():
 z=re.search(r'logic\s*(?:\[(\d+):(\d+)\])?\s*([^;]+);',line.split('//')[0])
 if z:
  width=int(z[1])-int(z[2])+1 if z[1]else 1
  for n in z[3].split(','):fields.append((n.strip(),width))
offset=301;layout={}
for n,width in fields:offset-=width;layout[n]=(offset,width)
assert offset==0
r=json.loads((W/'build/cpu232-controller-screen/result.json').read_text());controls=[];care=[];donly=[]
for f in r['source_field_inventory']:
 if f['live']:
  care.extend(range(f['offset'],f['offset']+f['declared']))
  if f['kind']=='template_candidate':controls.extend(range(f['offset'],f['offset']+f['declared']))
 else:donly.extend(range(f['offset'],f['offset']+f['declared']))
# Reconstruct only consumed E fields; retain the original D-only fields for D
# RF reads/shift prep. The miter compares the entire D packet, plus live E mask.
recon='''module ctlrom_reconstruct import arm_pkg::*; ('''+ports+'''input logic[300:0]shape,input logic[23:0]route,output logic[300:0]packet);
'''+const+typ+helpers+setup.replace('uop9_t u,u0;','uop9_t u,u0;')+'''
always_comb begin
 logic[31:0]pc8,link4,immv,linkv;logic[4:0]bank;logic[3:0]wr;logic[4:0]cnt;logic[31:0]evec;
 u=uop9_t'(shape);pc8=h_pc+(h_th?32'd4:32'd8);link4=h_pc+(h_th?32'd2:32'd4);
 cnt=c_ins[15:0]==0?5'd16:popcnt16(c_ins[15:0]);
 evec=(h_ab?32'h0c:take_fiq?32'h1c:take_irq?32'h18:(c_cls==C_SWI?32'h08:c_cls==C_BKPT?32'h0c:32'h04));
 immv=0;
 case(route[3:0])
  1:immv={24'd0,c_ins[7:0]};2:immv={24'd0,c_ins[11:8],c_ins[3:0]};3:immv={20'd0,c_ins[11:0]};
  4:immv={25'd0,cnt,2'b0};5:immv=c_tgt;6:immv={20'd0,c_ins[10:0],1'b0};7:immv=c_bl2t;
  8:immv=(hivec?32'hffff0000:32'd0)+evec;
  default:;
 endcase
 linkv=0;
 case(route[6:4])
  1:linkv=link4;2:linkv=c_tgt;3:linkv=link4|32'd1;4:linkv=h_th?(link4|32'd1):link4;5:linkv=h_pc+32'd4;default:;
 endcase
 wr=0;
 case(route[14:12])
  1:wr=c_ins[15:12];2:wr=c_ins[19:16];3:wr=ustep==1?c_ins[15:12]:{c_ins[15:13],1'b1};4:wr=rl_r;5:wr=4'he;default:;
 endcase
 bank=route[16:15]==1?mode_in:route[16:15]==2?route[23:19]:M_USR;
 u.pc=h_pc;u.pcv=0;
 if(route[8:7]==1)u.pcv=qpa?{pc8[31:2],2'b0}:pc8;
 else if(route[8:7]==2)u.pcv=h_pc+32'd12;
 u.pcv_c=route[9]?h_pc+32'd12:32'd0;
 u.imm=immv;u.link=linkv;u.cond=route[11:10]==1?c_ins[31:28]:route[11:10]==2?4'he:route[11:10]==3?4'hf:4'd0;
 u.wa=phys_reg(wr,bank);u.lw=wr;u.cp_op=route[18]?{2'b00,c_ins[23:21],c_ins[19:16],c_ins[3:0],c_ins[7:5]}:16'd0;
 u.msr_mask=route[17]?c_ins[19:16]:4'd0;u.exc_mode=route[23:19];
end
assign packet=u;
endmodule
'''
# setup contains nrl_r helpers/unused state but reconstruction has no original D
# decoder. All unused fields optimize away in the standalone graph.
(S/'ctlrom_reconstruct.sv').write_text(recon)
args=['c_ins','h_pc','c_bl2t','f_hw','rl_rem','c_cls','mode_in','rl_r','c_kind','ustep','h_th','h_ab','h_v','qpa','c_bl2','take_fiq','take_irq','hivec'];bindings=','.join('.'+x for x in args)
miter='module ctlrom_miter('+ports+'output logic bad);\nlogic[300:0]oldp,newp,tagp;logic[23:0]route;\n'
miter+='ctlrom_decode_before oldd('+bindings+',.packet(oldp),.route());\n'
miter+='ctlrom_decode tagd('+bindings+',.packet(tagp),.route);\n'
# Shape exposes only the non-data template and D-only routing bits. For proof
# this is the original narrow descriptor; candidate ROM roundtrip comes later.
mask=sum(1<<i for i in set(controls+donly+[layout['valid'][0],layout['thumb'][0]]))
miter+=f"ctlrom_reconstruct rebuild({bindings},.shape(tagp & 301'h{mask:x}),.route,.packet(newp));\nassign bad=(oldp!=newp);\nendmodule\n"
(S/'ctlrom_miter.sv').write_text(miter)
(S/'arm_pkg.sv').write_bytes(subprocess.check_output(['git','show','232c26ac:rtl/arm/arm_pkg.sv'],cwd=W))
(D/'layout.json').write_text(json.dumps({'layout':layout,'controls':controls,'care':care,'donly':donly,'route_bits':24},indent=2)+'\n')
print('generated pure decoder, tagged routes and reconstruction miter')

# Source-level descriptor interface contains no old199bit data packet output.
# D-only bits retain exact RF/shift/scoreboard preparation, and sequence output.
groups=json.loads((W/'build/cpu232-controller-screen/result.json').read_text())['planes']
desc='module ctlrom_descriptor('+ports+'output logic[12:0]p0,output logic[13:0]p1,output logic[12:0]p2,output logic[18:0]p3,output logic[11:0]p4,p5,output logic[42:0]donly,output logic[22:0]seq);\nlogic[300:0]packet;logic[23:0]route;\nctlrom_decode semantic('+bindings+',.packet,.route,.seq);\n'
for i,group in enumerate(groups.values()):
 bits=[]
 for f in group['field_layout']:bits.extend(range(f['source_offset'],f['source_offset']+f['width']))
 desc+='assign p'+str(i)+'={'+','.join('packet['+str(b)+']'for b in reversed(bits))+'};\n'
desc+='assign p4=route[11:0];assign p5=route[23:12];\n'
desc+='assign donly={'+','.join('packet['+str(b)+']'for b in reversed(donly))+'};\nendmodule\n'
(S/'ctlrom_descriptor.sv').write_text(desc)
