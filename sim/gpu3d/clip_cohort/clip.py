#!/usr/bin/env python3
"""Complete shared-cohort clip relation, original controls and consumer fault."""
import argparse,hashlib,json,os,re,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--before',default='ba29970820b84b260d69663b049c5e7063ef74ca');p.add_argument('--red',type=int,choices=[0,1],default=1);p.add_argument('--mutant',action='store_true');a=p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10);out=a.out.resolve();out.mkdir(parents=True,exist_ok=True);started=Path('/proc/self/stat').read_text().rsplit(')',1)[1].split()[19]
status=out/'status.json'
def phase(v,active=1):
 d=json.loads(status.read_text())if status.exists()else{};d.update(phase=v,worker={'host':'Laptop','controller_pid':os.getpid(),'starttime':started,'active':active,'nice':10,'jobs':1,'threads':1},updated_at=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()));t=status.with_suffix('.tmp');s=json.dumps(d,indent=2)+'\n';assert len(s.encode())<2048;t.write_text(s);t.replace(status)
phase('clipcohort full relation starting red='+str(a.red)+' mutant='+str(a.mutant));print(f'controller_pid={os.getpid()} starttime={started} NI10/j1/t1 out={out}',flush=True)
vfn='rtl/gpu3d/gpu3d_gxvfin.sv';dfn='rtl/gpu3d/gpu3d_gxdiv.sv';old=subprocess.check_output(['git','show',a.before+':'+vfn],cwd=ROOT).decode();new=(ROOT/vfn).read_text();odiv=subprocess.check_output(['git','show',a.before+':'+dfn],cwd=ROOT).decode();ndiv=(ROOT/dfn).read_text()
if a.mutant:
 needle="else if (busy[ci] && !(first_hold && is_long[ci])) begin\n                    r[ci] <= r_next[ci]; q2[ci] <= q_next[ci];"
 assert ndiv.count(needle)==1
 ndiv=ndiv.replace(needle,needle.replace('q2[ci] <= q_next[ci];',"q2[ci] <= q_next[ci] ^ (ci == 8 ? 32'd1 : 32'd0); // actual lane8 E-step fault"))
def clip(src,name):return src[src.index('module gpu3d_gxclip #('):].split('endmodule',1)[0].replace('module gpu3d_gxclip #(',f'module {name} #(',1)+'endmodule\n'
def div(src,name):return src[src.index('module gpu3d_gxdivk #('):].replace('gpu3d_gxdivk',name)
oldhelper=old[old.index('module gpu3d_gxclip_input_bank #('):].split('endmodule',1)[0]+'endmodule\n'
(out/'before.sv').write_text((clip(old,'clip_before')+oldhelper).replace('gpu3d_gxclip_input_bank','bank_before').replace('gpu3d_gxdivk','div_before')+div(odiv,'div_before'))
helper=new[new.index('module gpu3d_gxclip_input_bank #('):].split('endmodule',1)[0]+'endmodule\n'
(out/'after.sv').write_text((clip(new,'clip_after')+helper).replace('gpu3d_gxdivk','div_after')+div(ndiv,'div_after'))
pkg=(ROOT/'rtl/gpu3d/gpu3d_gxu_pkg.sv').read_text();constants={n:int(v,16)for n,v in re.findall(r"localparam logic \[10:0\] (\w+) = 11'h([0-9A-Fa-f]+)",pkg)};(out/'addresses.h').write_text(''.join(f'constexpr unsigned {n}=0x{v:x};\n'for n,v in constants.items()))
params='.A_LA(FU_A_LA),.A_LN(FU_A_LN),.A_CS(FU_A_CS),.A_OCM(PU_A_OCM),.A_CATTR(LU_A_CATTR),.A_POOL(PU_A_POOL),.DS_CLIPRED(RED),.DIV_P2X(1)'
outs={'cond':1,'cw':1,'cwa':11,'cwd':32,'busy':1,'nnew':4,'nside':1,'nnew_v':1};ins='clk clk2 rst we wa wd run can wfree'.split()
top=['''module tb_clip_input #(parameter bit RED=1)(
input logic clk,clk2,rst,we,run,can,wfree,input logic[10:0]wa,input logic[31:0]wd,
output wire cond,cw,busy,nnew_v,output wire[10:0]cwa,output wire[31:0]cwd,output wire[3:0]nnew,output wire nside,
output wire[3:0]state,output wire[2:0]halfplane,output wire side,seg,start_div,pending,mid,
output wire[1:0]component,output wire[31:0]outside_word[9],inside_word[9],vw,vc,
output wire[63:0]num_word[9],output wire[31:0]quotient[9],output wire[8:0]divbusy,
output wire[17:0]read_valid,output wire[8:0]read_addr[18],
output logic[31:0]collisions=0,full_clocks=0,held=0,rf_takes=0,outcomes=0);
import gpu3d_gxu_pkg::*;
''']
for suffix,mod in [('a','clip_before'),('b','clip_after')]:
 for n,w in outs.items():top.append(f'wire[{w-1}:0]{n}_{suffix};')
 bound=params+(",.COHORT(1'b1)"if suffix=='b'else'')
 top.append(f'{mod} #({bound}) {suffix}('+','.join([f'.{n}({n})'for n in ins]+[f'.{n}({n}_{suffix})'for n in outs])+');')
for n in outs:top.append(f'assign {n}={n}_a;')
top.append('''assign state=a.st; assign halfplane=a.hx;assign side=a.side;assign component=a.comp;
assign seg=a.st==a.S_NB2&&!a.outs(a.inside_word[3],a.inside_word[a.comp],a.hm);
assign start_div=a.dgo;assign pending=b.g_input.u_bank.pending;assign mid=b.g_input.u_bank.mid;
assign vw=a.vw;assign vc=a.vc;assign divbusy=b.dbusy;
always_comb begin
read_valid='0;
if(a.st==a.S_HT&&a.li<a.ln)read_valid=18'h3;
if(a.st==a.S_NB&&a.nk==9&&a.rk==0)read_valid=18'h3ffff;
if(a.st==a.S_CM&&a.qe&&!a.pu&&a.k<a.ln)read_valid=18'h7;
end
''')
for i in range(9):
 top.append(f'assign outside_word[{i}]=a.outside_word[{i}];assign inside_word[{i}]=a.inside_word[{i}];')
 top.append(f'assign num_word[{i}]=b.g_input.u_bank.g_cohort.u_div.nfull[{i}];assign quotient[{i}]=b.dq[{i}];')
 word=i if i<7 else i+1
 top.append(f"assign read_addr[{i}]={{a.rgroup_out,4'd{word}}};assign read_addr[{9+i}]={{a.rgroup_in,4'd{word}}};")
top.append('logic started=0;always @(posedge clk)if(rst)started<=0;else if(a.dgo)started<=1;\nalways @(negedge clk)if(!rst)begin')
# Consumer first, so the negative deliberately reaches the RF boundary.
for n in outs:
 gate='cw_a'if n in ['cwa','cwd']else'nnew_v_a'if n in ['nnew','nside']else'1'
 if a.mutant and n in ['cwa','cwd']:gate="1'b0" # negative must reach an actual accepted edge
 top.append(f'if({gate}&&{n}_a!=={n}_b)$fatal(1,"clip RFconsumer/output {n} mismatch old=%h new=%h",{n}_a,{n}_b);')
for n in ['st','done','cur','ln','li','lcnt','cs','ocm','far12','newv','pool0','pool','hx','side','v','u','vw','vc','num','den','k','pts','rv','ru','dgo','dwait','qw','qr','nk','rk','nva','ck','sn_ln','sn_cs','sn_ocm','sn_far','sn_pool']:
 top.append(f'if(a.{n}!==b.{n})$fatal(1,"clip state {n} mismatch");')
top.append('for(int i=0;i<10;i++)if(a.sn_la[i]!==b.sn_la[i]||a.la[i]!==b.la[i]||a.lb[i]!==b.lb[i])$fatal(1,"clip list state mismatch");')
for i in range(9):
 top.append(f'if(a.vin[{i}]!==b.vin[{i}])$fatal(1,"clip vin[{i}] mismatch");')
 if not(a.mutant and i==8):
  top.append(f'if(a.nv[{i}]!==b.nv[{i}])$fatal(1,"clip nv[{i}] mismatch");')
  top.append(f'if(started&&(a.dq[{i}]!==b.dq[{i}]||a.dbusy[{i}]!==b.dbusy[{i}]))$fatal(1,"clip q/busy[{i}] mismatch");')
  for n in ['nfull','r','q2']:
   top.append(f'if(a.dbusy[{i}]&&a.g_input.u_bank.g_div[{i}].u_d.g_p2.{n}!==b.g_input.u_bank.g_cohort.u_div.{n}[{i}])$fatal(1,"clip active arithmetic[{i}] {n} mismatch");')
  cref='b.g_input.u_bank.g_cohort.u_div'
  top.append(f"if(a.dbusy[{i}]&&(a.g_input.u_bank.g_div[{i}].u_d.g_p2.d!=={cref}.d || a.g_input.u_bank.g_div[{i}].u_d.g_p2.first!=={cref}.first || a.g_input.u_bank.g_div[{i}].u_d.g_p2.rsm!==({cref}.first_hold && {cref}.is_long[{i}]) || a.g_input.u_bank.g_div[{i}].u_d.g_p2.cnt!==({cref}.first ? 7'd32 : {cref}.is_long[{i}] ? {cref}.long_count : {cref}.normal_count)))$fatal(1,\"cohort progress relation[{i}] mismatch\");")
 top.append(f'if(a.outside_word[{i}]!==b.outside_word[{i}]||a.inside_word[{i}]!==b.inside_word[{i}])$fatal(1,"clip registered RAM[{i}] mismatch");')
top.append('for(int i=0;i<3;i++)if(a.cm[i]!==b.cm[i])$fatal(1,"clip CM state mismatch");')
if not a.mutant:top.append('for(int i=0;i<32;i++)if(a.u_write_queue.mem[i]!==b.u_write_queue.mem[i])$fatal(1,"clip queue storage mismatch");')
top.append('''end
always @(posedge clk)if(!rst)begin
collisions<=collisions+32'(we&&wa[10:9]==2'b01&&read_valid!=0);
full_clocks<=full_clocks+32'(a.qfull);held<=held+32'(cw_a&&!wfree);
rf_takes<=rf_takes+32'(cw_a&&wfree);outcomes<=outcomes+32'(nnew_v_a);
end
endmodule
''')
if a.mutant:top[-1]=top[-1].rsplit('endmodule',1)[0]+'always @(posedge clk)if(!rst&&cw_a&&wfree&&(cwa_a!==cwa_b||cwd_a!==cwd_b))$fatal(1,"clip RFconsumer/output cwd mismatch on accepted RF edge old=%h new=%h",cwd_a,cwd_b);'+'\nendmodule\n'
(out/'wrapper.sv').write_text('\n'.join(top));(out/'main.cpp').write_bytes((ROOT/'sim/gpu3d/clip_input/main.cpp').read_bytes())
cmd=['build/tools/oss-cad-suite/bin/verilator','--cc','--exe','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','tb_clip_input',f'-GRED={a.red}','--Mdir',str(out/'obj'),'-MAKEFLAGS','VM_PARALLEL_BUILDS=0','-CFLAGS',f'-std=c++20 -O1 -I{out} -DRED={a.red}',str(ROOT/'rtl/gpu3d/gpu3d_gxu_pkg.sv'),str(ROOT/'rtl/gpu3d/gpu3d_ram.sv'),str(out/'before.sv'),str(out/'after.sv'),str(out/'wrapper.sv'),str(out/'main.cpp')]
def capacity():
 rows=[s.split(None,3)for s in subprocess.check_output(['ps','-eo','pid,ppid,ni,comm'],text=True).splitlines()[1:]];parents={int(p):int(pp)for p,pp,_,_ in rows}
 def ancestors(n):
  v=set()
  while n in parents and n not in v:v.add(n);n=parents[n]
  return v
 heavy={int(p)for p,_,_,c in rows if c.startswith(('V','verilator_bin','clang','census'))or c in('cc1plus','cc1','lto1')};leaves={n for n in heavy if not any(n in ancestors(o)-{o}for o in heavy)};foreign=[n for n in leaves if os.getpid()not in ancestors(n)]
 with(out/'capacity.jsonl').open('a')as f:f.write(json.dumps({'time':time.time(),'foreign':foreign,'allowed':2})+'\n')
 return len(foreign)<=2
while not capacity():print('WAIT global<=3',flush=True);time.sleep(5)
with(out/'build.log').open('w')as f:rc=subprocess.run(cmd,cwd=out,stdout=f,stderr=subprocess.STDOUT).returncode
if rc:phase('clipcohort buildfailed '+str(rc),0);raise SystemExit('buildfailed')
print('BUILD_PASS',flush=True);phase('clipcohort complete relation running')
while not capacity():print('WAIT global<=3',flush=True);time.sleep(5)
run=[str(out/'obj/Vtb_clip_input')]+(['--consumer-fault']if a.mutant else[])
with(out/'run.log').open('w')as f:rc=subprocess.run(run,cwd=out,stdout=f,stderr=subprocess.STDOUT).returncode
r={'before':a.before,'hashes':{'before_clip':hashlib.sha256(old.encode()).hexdigest(),'after_clip':hashlib.sha256(new.encode()).hexdigest(),'before_div':hashlib.sha256(odiv.encode()).hexdigest(),'after_div':hashlib.sha256(ndiv.encode()).hexdigest()},'command':cmd,'run_command':run,'red':a.red,'mutant':a.mutant,'exit':rc,'controller':os.getpid(),'starttime':started,'nice':10,'jobs':1,'threads':1};(out/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');log=(out/'run.log').read_text();print(log,flush=True);phase('clipcohort terminal rc='+str(rc)+' mutant='+str(a.mutant),0)
if(rc==0)==a.mutant:raise SystemExit('unexpected verdict')
if a.mutant and not any(x in log for x in ['RFconsumer/output cwd mismatch','RFconsumer/output cwa mismatch']):raise SystemExit('actual fault not caught at RF consumer')
