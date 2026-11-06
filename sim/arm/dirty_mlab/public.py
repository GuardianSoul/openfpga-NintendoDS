#!/usr/bin/env python3
from pathlib import Path
import re,subprocess,os,json,resource,sys
R=Path(__file__).resolve().parents[3];fault='--fault' in sys.argv;main_profile='--main-profile' in sys.argv;D=R/('build/main-dirty-mlab-profile' if main_profile else 'build/main-dirty-mlab-public-fault' if fault else 'build/main-dirty-mlab-public');D.mkdir(parents=True,exist_ok=True);os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
s=(R/'rtl/arm/arm9_mem.sv').read_text();old=subprocess.check_output(['git','show','2c4e980c:rtl/arm/arm9_mem.sv'],cwd=R,text=True).replace('module arm9_mem import','module arm9_mem_before import',1);(D/'before.sv').write_text(old)
ports=s[s.index('  input  logic        clk,'):s.index('\n);')];ports=re.sub(r'//[^\n]*','',ports);found=re.findall(r'(input|output)\s+(?:logic|wire)\s*(\[[^\]]+\])?\s*(\w+)',ports)
decls=['reg clk2=0;'];connections=[[],[]];outs=[]
for direction,width,name in found:
 if direction=='input':
  decls.append(f'reg {width} {name}=0;');connections[0].append('.'+name+'('+name+')');connections[1].append('.'+name+'('+name+')')
 else:
  for i in range(2):decls.append(f'wire {width} {name}{i};');connections[i].append('.'+name+'('+name+str(i)+')')
  outs.append(name)
tb='`timescale 1ns/1ps\nmodule tb;\n'+ '\n'.join(decls)+'\n'
for i,mod in enumerate(['arm9_mem_before','arm9_mem']):tb+=mod+" #(.SLOW(1),.OPT(461366243),.NCNB_WAIT(1),.EVB(1),.BURST(1)"+(",.DIRTY_MLAB(1)" if i else '')+(', .READ_ACK_EARLY(1)' if main_profile else '')+') u'+str(i)+'('+','.join(connections[i])+');\n'
tb+='''integer cycles=0,sets=0,clears=0,tags=0,dirtytags=0,evictions=0,ncnb=0;integer a,b,t,w;reg[31:0]data=32'h714b8a32;
task tick;
begin
 clk=0;#4;clk2=1;#1;
'''
for n in outs:tb+=f'if({n}0!=={n}1)$fatal(1,"public mismatch {n} cycle%0d",cycles);\n'
tb+='''if(u0.st!==u1.st||u0.ev_lane!==u1.ev_lane||u0.wb_n!==u1.wb_n||u0.nb_owned!==u1.nb_owned)$fatal(1,"state/order mismatch cycle%0d",cycles);
for(a=0;a<32;a=a+1)for(b=0;b<4;b=b+1)begin
case(b)
0:if(u0.dirt[a][b]!==u1.g_dirty_mlab.way[0].u_bank.mem[a])$fatal(1,"dirty mismatch way0 cycle%0d",cycles);
1:if(u0.dirt[a][b]!==u1.g_dirty_mlab.way[1].u_bank.mem[a])$fatal(1,"dirty mismatch way1 cycle%0d",cycles);
2:if(u0.dirt[a][b]!==u1.g_dirty_mlab.way[2].u_bank.mem[a])$fatal(1,"dirty mismatch way2 cycle%0d",cycles);
3:if(u0.dirt[a][b]!==u1.g_dirty_mlab.way[3].u_bank.mem[a])$fatal(1,"dirty mismatch way3 cycle%0d",cycles);
endcase end
if(u1.dirty_set)sets=sets+1;if(u1.dirty_clear)clears=clears+1;
if(u0.st==u0.S_TAG && u0.k!=0)begin tags=tags+1;end
if(u0.st==u0.S_EVRD)evictions=evictions+1;if(u0.nb_owned)ncnb=ncnb+1;
clk=1;#1;clk2=0;#4;clk=0;cycles=cycles+1;
end endtask
task cp(input[3:0]crn,input[3:0]crm,input[2:0]op,input[31:0]val);
begin cp_req=1;cp_we=1;cp_op={1'b0,crn,crm,op};cp_wdata=val;tick();tick();cp_req=0;cp_we=0;repeat(4)tick();end endtask
task access(input[31:0]adr,input wr);
integer timeout;
begin d_req=1;d_we=wr;d_addr=adr;d_wdata=data;d_be=(cycles%15)+1;data={data[30:0],data[31]^data[21]^data[1]^data[0]};
tick();tick();timeout=0;
while(!d_ok0 && timeout<300)begin tick();timeout=timeout+1;end
if(timeout==300)$fatal(1,"request timeout");d_req=0;tick();repeat(2)tick();end endtask
initial begin
cpu_solo=1;i_priv=1;d_priv=1;b_ack=1;b_rdata=32'h5a1df00d;rst=1;repeat(3)tick();rst=0;
cp(6,0,0,32'h3f);cp(5,0,0,32'hffffffff);cp(2,0,0,1);cp(3,0,0,1);cp(1,0,0,5);
// Nonuniform dirty subset: only way0 dirty, then replace way0.
// Uniform all-dirty populations alone can hide a permuted-way fault.
for(t=0;t<4;t=t+1)access(32'h02000000+t*1024,0);
access(32'h02000000,1);access(32'h02001000,0);
// Fill/dirty/replacement with every set and way, unchanged bus ACK edges.
for(t=0;t<768;t=t+1)begin
access(32'h02000000+(t%32)*32+((t/32)%8)*1024,0);
access(32'h02000000+(t%32)*32+((t/32)%8)*1024,1);
end
// Clean/invalidate/set-way aliases and reset with resident dirty state.
cp(7,10,0,0);repeat(100)tick();cp(7,6,0,0);repeat(100)tick();
rst=1;repeat(4)tick();rst=0;repeat(20)tick();
// NCNB exact owned write/real ACK after cache-disabled reset.
for(t=0;t<32;t=t+1)access(32'h02002000+t*4,1);
if(sets<128||clears<128||evictions==0||ncnb==0)$fatal(1,"coverage sets%0d clears%0d ev%0d ncnb%0d",sets,clears,evictions,ncnb);
$display("PASS_PUBLIC cycles%0d sets%0d clears%0d tags%0d evictions%0d ncnb%0d",cycles,sets,clears,tags,evictions,ncnb);$finish;
end
endmodule
'''
if main_profile:
 tb=tb.replace('ncnb=0;', 'ncnb=0,ldmacks=0,earlyreturns=0;')
 tb=tb.replace('if(u0.nb_owned)ncnb=ncnb+1;', 'if(u0.nb_owned)ncnb=ncnb+1;if(u0.ldm_ack)ldmacks=ldmacks+1;if(u0.read_return)earlyreturns=earlyreturns+1;')
 marker='if(sets<128||clears<128'
 extra="""d_block=1;d_ldm_meta=7'b1101101;
for(t=0;t<8;t=t+1)access(32'h02003000+t*4,0);
d_block=0;d_ldm_meta=0;
for(t=0;t<8;t=t+1)access(32'h04000100+t*4,0);
if(ldmacks==0||earlyreturns==0)$fatal(1,"mainprofile coverage LDM%0d IO%0d",ldmacks,earlyreturns);
$display("PASS_MAIN_PROFILE LDMacks%0d earlyIOreturns%0d",ldmacks,earlyreturns);
"""
 tb=tb.replace(marker,extra+marker)
if fault:
 # Require the actual wrong-way mutation to escape through public outputs,
 # rather than stopping at the earlier internal dirty-state witness.
 a=tb.index('if(u0.st!==');b=tb.index('if(u1.dirty_set)',a);tb=tb[:a]+tb[b:]
(D/'tb.sv').write_text(tb)
T=Path('build/tools/oss-cad-suite/bin');receipt={'PID':os.getpid(),'NI':10,'jobs':1,'threads':1,'stages':[]}
def run(name,cmd):
 with (D/(name+'.log')).open('w')as log:
  p=subprocess.Popen(list(map(str,cmd)),stdout=log,stderr=subprocess.STDOUT);receipt['stages'].append({'name':name,'PID':p.pid});(D/'receipt.json').write_text(json.dumps(receipt));rc=p.wait(timeout=120);receipt['stages'][-1].update(exit=rc,reaped=True);(D/'receipt.json').write_text(json.dumps(receipt));assert rc==0,(name,(D/(name+'.log')).read_text()[-2000:])
 print(name,(D/(name+'.log')).read_text()[-300:],flush=True)
cmd=[T/'verilator','--binary','--timing','--assert','--threads','1','-j','1','-O1','-Wno-fatal','--top-module','tb','--Mdir',D/'obj',R/'rtl/arm/arm_pkg.sv',R/'rtl/arm/arm9_ram.sv',D/'before.sv',R/'rtl/arm/arm9_mem.sv',D/'tb.sv']
if fault:
 mutant=s.replace("wd_way == WB'(dw)","wd_way == WB'(dw ^ 1)",1)
 assert mutant!=s
 (D/'mutant.sv').write_text(mutant);cmd[cmd.index(R/'rtl/arm/arm9_mem.sv')]=D/'mutant.sv'
run('build',cmd)
if fault:
 with (D/'fault.log').open('w') as f:
  p=subprocess.Popen([str(D/'obj/Vtb')],stdout=f,stderr=subprocess.STDOUT);rc=p.wait(timeout=90)
 receipt['stages'].append({'name':'actual-wrong-way','PID':p.pid,'exit':rc,'reaped':True})
 assert rc!=0 and 'mismatch' in (D/'fault.log').read_text()
 print((D/'fault.log').read_text(),flush=True)
else:run('public',[D/'obj/Vtb'])
receipt['status']='CAUGHT_ACTUAL_WRONG_WAY' if fault else 'PASS_PUBLIC';(D/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
