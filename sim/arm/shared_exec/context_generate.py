#!/usr/bin/env python3
"""Fixed context packed stores from immutable complete elastic donor15c.
One write and one async read per wide stage, valid tokens remain resettable FFs.
No old CPU controller or extra execution engine is instantiated.
"""
from pathlib import Path
import subprocess,re
W=Path(__file__).resolve().parents[3];P=W/'rtl/arm/study';REF='15c3299db4acd3e01874292ac0db9c810565ff7a'
def source(name):return subprocess.check_output(['git','show',REF+':rtl/arm/study/'+name+'.sv'],cwd=W,text=True)
s=source('arm_shared_elastic').replace('module arm_shared_elastic ', 'module arm_shared_context ')
s=s.replace("  parameter bit FAULT_FORWARD", "  parameter STORE_STYLE = \"MLAB\",\n  parameter bit STORE_SYNC = 1'b0,\n  parameter bit FAULT_CONTEXT = 1'b0, // proof-only incorrect backing-store owner\n  parameter bit FAULT_FORWARD",1)
a=s.index('  // Rotating odd-stage banks:');b=s.index('  logic [1:0] paused;',a)
old=s[a:b];decls={}
for m in re.finditer(r'\b(uop_t|logic\s*(?:\[[^\]]+\])?)\s+(\w+)_ctx\s*\[0:1\];',old):decls[m[2]]=m[1]
e2=[n for n in decls if n=='e2'or n.startswith('e2_')];wb=[n for n in decls if n.startswith('w_')];assert len(e2)==18 and len(wb)==44,(len(e2),len(wb))
# Extract original producer logic before rewriting its assignments.
x=s.index('      if(advance_e) begin\n      // ---- E1 (te)');y=s.index('      end\n      // ---- E2 (to)',x)
e1body=s[x+len('      if(advance_e) begin\n'):y]
xw=s.index('      w_valid_ctx[1] <=');yw=s.index('\n      end\n      // ---- WB (to)',xw);wbody=s[xw:yw]
# Validity is outside RAM; BP must not read an uninitialized invalid payload.
store='''  // Fixed physical contexts: each packed payload has one write/one async read.
  // Consumer uses c1 before the edge; producer writes c0, a different row.
  // After tid changes, the new c1 sees the just-produced row within clk2 setup.
'''
for tag,ns in [('e2',e2),('wb',[n for n in wb if n!='w_valid'])]:
 store+='  typedef struct packed {\n'
 for n in ns:store+=f'    {decls[n]} {"op"if n=="e2"else n};\n'
 store+=f'  }} {tag}_store_t;\n  {tag}_store_t {tag}_next, {tag}_read;\n  arm_context_bank #(.WIDTH($bits({tag}_store_t)),.STYLE(STORE_STYLE),.SYNC(STORE_SYNC),.FAULT_OWNER(FAULT_CONTEXT)) {tag}_bank(.clk(clk),.we(!rst && advance_e),.even_owner(c0),.odd_owner(c1),.wdata({tag}_next),.rdata({tag}_read));\n'
store+='  logic [1:0] e2_valid_fixed,w_valid_fixed,f2_valid_fixed,f2_seen_fixed;\n  logic [1:0] f2_counter_fixed[0:1];\n  logic [32:0] f2_word;\n  arm_context_bank #(.WIDTH(33),.STYLE(STORE_STYLE),.SYNC(STORE_SYNC)) f2_bank(.clk(clk),.we(!rst && fetch_en),.even_owner(c0),.odd_owner(c1),.wdata({fetch_thumb[0],fetch_pc[0]}),.rdata(f2_word));\n'
for n in e2+wb+['f2_v','f2_pc','f2_thumb']:
 typ=decls[n];store+=f'  {typ} {n}_ctx[0:1]; // compatibility views, not rotating state\n'
 if n=='e2':
  store+='  always_comb begin\n    e2=e2_read.op; e2.valid=e2_valid_fixed[c1];\n    e2_ctx[0]=\'0; e2_ctx[0].valid=e2_valid_fixed[c0]; e2_ctx[1]=e2;\n  end\n';continue
 if n=='w_valid':rhs='w_valid_fixed[c1]';r0='w_valid_fixed[c0]'
 elif n=='w_bp':rhs='wb_read.w_bp && w_valid_fixed[c1]';r0="1'b0"
 elif n=='f2_v':rhs='f2_valid_fixed[c1]';r0='f2_valid_fixed[c0]'
 elif n=='f2_pc':rhs='f2_word[31:0]';r0="'0"
 elif n=='f2_thumb':rhs='f2_word[32]';r0="1'b0"
 else:rhs=('e2_read.'if n.startswith('e2_')else'wb_read.')+n;r0="'0"
 store+=f'  assign {n}={rhs};\n  assign {n}_ctx[0]={r0}; assign {n}_ctx[1]={n};\n'
# c0 F2 payload view is debug-only except validity; synthesis removes that read.
s=s[:a]+store+s[b:]
# Default next-data producers; all state inputs are unchanged donor expressions.
e1body=e1body.replace('      // ---- E1 (te)','')
for n in sorted(e2,key=len,reverse=True):e1body=e1body.replace(n+'_ctx[1]', 'e2_next.'+('op'if n=='e2'else n))
e1body=e1body.replace('<=','=')
e1body+='      e2_next.op.valid=0; // token is stored in resettable FFs\n'
wbody=wbody.replace('      w_valid_ctx[1] <= e3.valid && !x2_rdr;','')
for n in sorted(wb,key=len,reverse=True):wbody=wbody.replace(n+'_ctx[1]','wb_next.'+n)
wbody=wbody.replace('<=','=')
block='''  always_comb begin
    e2_next='0;
'''+e1body+'''  end
  always_comb begin
    wb_next='0;
'''+wbody+'''  end
'''
pos=s.index('`ifndef SYNTHESIS\n`ifndef ALTERA_RESERVED_QIS\n  initial if(A9_SOLO');s=s[:pos]+block+s[pos:]
# Replace wide producer sections in main FF block with resettable valid only.
x=s.index('      if(advance_e) begin\n      // ---- E1 (te)');y=s.index('      end\n      // ---- E2 (to)',x)+len('      end\n')
s=s[:x]+'''      if(advance_e) e2_valid_fixed[c0]<=e1.valid && !kill_e && !(solo && wb_kill);
'''+s[y:]
x=s.index('      w_valid_ctx[1] <=');y=s.index('\n      end\n      // ---- WB (to)',x)
s=s[:x]+'''      w_valid_fixed[c0]<=e3.valid && !x2_rdr;
'''+s[y:]
# Remove all rotations of these banks and their old reset/producer assignments.
s=re.sub(r'      \w+_ctx\[0\]<=\w+_ctx\[1\]; \w+_ctx\[1\]<=\w+_ctx\[0\];\n','',s)
s=s.replace('      f2_v_ctx[0] <= 0; f2_v_ctx[1] <= 0;', '      f2_valid_fixed<=0; e2_valid_fixed<=0; w_valid_fixed<=0;')
s=s.replace("      e2_ctx[0]<='0; e2_ctx[1]<='0;\n",'')
for n in ['w_valid','w_bp','w_exec']:s=s.replace(f'      {n}_ctx[0] <= 0; {n}_ctx[1] <= 0;\n','')
s=s.replace('paused<=0; f2_seen_ctx[0]<=0; f2_seen_ctx[1]<=0;', 'paused<=0; f2_seen_fixed<=0;')
s=s.replace('  logic [1:0] f2_ctr_ctx[0:1];\n  logic f2_seen_ctx[0:1];', '''  wire [1:0] f2_ctr_ctx[0:1];
  wire f2_seen_ctx[0:1];
  assign f2_ctr_ctx[0]=f2_counter_fixed[c0]; assign f2_ctr_ctx[1]=f2_counter_fixed[c1];
  assign f2_seen_ctx[0]=f2_seen_fixed[c0]; assign f2_seen_ctx[1]=f2_seen_fixed[c1];''')
# Its named rotations were removed above. Remaining odd-side predictor and valid writes:
s=s.replace('f2_ctr_ctx[0]<=bp_q; f2_seen_ctx[0]<=1;', 'f2_counter_fixed[c1]<=bp_q; f2_seen_fixed[c1]<=1;')
s=s.replace('f2_v_ctx[0]<=0;', 'f2_valid_fixed[c1]<=0;').replace('f2_v_ctx[1]<=0;', 'f2_valid_fixed[c0]<=0;')
s=s.replace('f2_v_ctx[1]<=1; f2_pc_ctx[1]<=fetch_pc[0];\n        f2_thumb_ctx[1]<=fetch_thumb[0]; f2_seen_ctx[1]<=0;', 'f2_valid_fixed[c0]<=1; f2_seen_fixed[c0]<=0;')
assert not re.search(r'\w+_ctx\[\d\](?:\.\w+)?\s*<=',s),re.findall(r'\w+_ctx\[\d\](?:\.\w+)?\s*<=',s)
# The F2 c0 metadata aliases need no extra synthesis read because only c1 consumes payload.
s=s.replace('assign f2_pc_ctx[0]=f2_backing[c0][31:0];',"assign f2_pc_ctx[0]='0;").replace('assign f2_thumb_ctx[0]=f2_backing[c0][32];',"assign f2_thumb_ctx[0]=0;")
(P/'arm_shared_context.sv').write_text(s)
s=source('arm_dual_elastic').replace('module arm_dual_elastic #(parameter bit FAULT_OWNER=0)', 'module arm_dual_context #(parameter bit FAULT_OWNER=0, parameter STORE_STYLE="MLAB", parameter bit STORE_SYNC=0, parameter bit FAULT_CONTEXT=0)')
s=s.replace('arm_shared_elastic #(', 'arm_shared_context #(.STORE_STYLE(STORE_STYLE),.STORE_SYNC(STORE_SYNC),.FAULT_CONTEXT(FAULT_CONTEXT),')
(P/'arm_dual_context.sv').write_text(s)
s=source('arm_cpu_elastic').replace('module arm_cpu_elastic #(', 'module arm_cpu_context #(parameter STORE_STYLE="MLAB",parameter bit STORE_SYNC=0,parameter bit FAULT_CONTEXT=0,')
s=s.replace('arm_dual_elastic #(', 'arm_dual_context #(.STORE_STYLE(STORE_STYLE),.STORE_SYNC(STORE_SYNC),.FAULT_CONTEXT(FAULT_CONTEXT),')
(P/'arm_cpu_context.sv').write_text(s)
print('packed',len(e2),'E2 fields and',len(wb)-1,'WB fields; fixed33bit F2 payload; reset FF tokens; STYLE selectable')
