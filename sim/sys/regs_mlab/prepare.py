#!/usr/bin/env python3
from pathlib import Path
import subprocess,json,re,hashlib,shutil
R=Path(__file__).resolve().parents[3];D=Path('/home/user/Git/NDS_Pocket/build/sys-regs-mlab-l1');D.mkdir(exist_ok=True)
BASE='249157de78006fadea4ca0cca53787e3734a7ac2';files=['sys_ram','sys_irq','sys_timers','sys_ipc','sys_math','sys_dma','nds_sys'];old={f:subprocess.check_output(['git','show',BASE+':rtl/sys/'+f+'.sv'],cwd=R,text=True)for f in files};names={n for s in old.values()for n in re.findall(r'\bmodule\s+(\w+)',s)};pat=re.compile(r'\b('+'|'.join(sorted(names,key=len,reverse=True))+r')\b')
for f in files:
 (D/('old_'+f+'.sv')).write_text(pat.sub(lambda m:'old_'+m[0],old[f]));s=(R/'rtl/sys'/(f+'.sv')).read_text()
 if f=='nds_sys':s=s.replace('module nds_sys #(','module new_nds_sys #(')
 (D/(f+'.sv')).write_text(s)
for f in ['rtl/ds/nds_dsp_add.sv','sim/sys/golden_sys.h']:shutil.copy2(R/f,D/Path(f).name)
for f in ['worker.py','primitive.sv','tb_regs.sv']:shutil.copy2(R/'sim/sys/regs_mlab'/f,D/f)
s=(R/'rtl/sys/nds_sys.sv').read_text();ports=s[s.index(') (')+3:s.index(');',s.index(') ('))];ports=re.sub(r'//[^\n]*','',ports);items=re.findall(r'\b(input|output)\s+logic\s*(\[[^\]]+\])?\s*(\w+)',ports)
wrapper='module nds_sys ('+ports.rstrip()+',input logic do_import, output logic diff,state_diff, output logic[31:0] imports,arb_stalls,collisions,dma_loads,reg_reads,reg_writes);\n'
for d,w,n in items:
 if d=='output':wrapper+=f'wire {w} old_{n};\n'
conn=lambda before:','.join('.'+n+'('+('old_'if before and d=='output'else'')+n+')'for d,w,n in items)
wrapper+='new_nds_sys #(.REG_MLAB(1),.DMA_FAST(1)) n('+conn(False)+');\nold_nds_sys #(.DMA_FAST(1)) o('+conn(True)+');\nalways_comb begin diff=0;state_diff=0;\n'
for d,w,n in items:
 if d=='output':
  gate='1'
  if n=='io_rdata':gate='io_hit'
  if n in ['m_we','m_cpu','m_size32','m_addr','m_unit','m_more']:gate='m_req'
  if n=='m_wdata':gate='m_req&&m_we'
  if n=='m_dst':gate='m_req&&m_unit'
  wrapper+=f'if({gate}&&{n}!==old_{n})diff=1;\n'
for f in ['en','run','inprog','resume','ek','lr_v','lr_k','est','e_cnt','e_src','e_dst','e_data','e_rem','e_chunk','e_res','e_why','rtag','fin_irq']:wrapper+=f'if(n.u_dma.{f}!==o.u_dma.{f})state_diff=1;\n'
wrapper+='end\ninitial begin imports=0;arb_stalls=0;collisions=0;dma_loads=0;reg_reads=0;reg_writes=0;end\nalways @(posedge clk)begin\nif(o.cpu_rg)reg_reads<=reg_reads+1;\nif(o.wr&&o.rg_hit)reg_writes<=reg_writes+1;\nif(o.u_dma.eng_rgo)dma_loads<=dma_loads+1;\nif(o.cpu_rg&&(o.u_dma.est==o.u_dma.E_RCNT||o.u_dma.est==o.u_dma.E_RSD))arb_stalls<=arb_stalls+1;\nif(o.wr&&o.rg_hit&&{io_cpu,o.rg_idx}==(o.cpu_rg?{io_cpu,o.rg_idx}:o.dma_raddr))collisions<=collisions+1;\nend\n'
wrapper+='logic[63:0]captured[0:31];time freeze_time;\nalways @(posedge do_import)begin\nassert(!clk&&n.g_regs_mlab.u_regs.pending_be==0)else $fatal(1,"REG_IMPORT_NOT_HELD");freeze_time=$time;\nfor(integer a=0;a<32;a++)captured[a]=o.u_regs.mem[a];\n'
for j in range(8):
 wrapper+=f'''for(integer a=0;a<32;a++)begin
`ifdef ALTERA_RESERVED_QIS
 n.g_regs_mlab.u_regs.g_byte[{j}].u_lane.u_ram.mem_data[a]=~captured[a][{j*8}+:8];
 n.g_regs_mlab.u_regs.g_byte[{j}].u_lane.u_ram.mem_data[a]=captured[a][{j*8}+:8];
 assert(n.g_regs_mlab.u_regs.g_byte[{j}].u_lane.u_ram.mem_data[a]===captured[a][{j*8}+:8])else $fatal(1,"REG_IMPORT_BYTE{j}");
`else
 n.g_regs_mlab.u_regs.g_byte[{j}].u_lane.mem[a]=~captured[a][{j*8}+:8];
 n.g_regs_mlab.u_regs.g_byte[{j}].u_lane.mem[a]=captured[a][{j*8}+:8];
 assert(n.g_regs_mlab.u_regs.g_byte[{j}].u_lane.mem[a]===captured[a][{j*8}+:8])else $fatal(1,"REG_IMPORT_BYTE{j}");
`endif
end
'''
wrapper+='assert($time==freeze_time)else $fatal(1,"REG_IMPORT_TICK");imports++;\nend\nendmodule\n';(D/'wrapper.sv').write_text(wrapper)
cpp=(R/'sim/sys/tb_sys.cpp').read_text().replace('top->clk = 1; top->eval();','top->clk = 1; top->eval();\n if(top->diff){printf("SYS_REG_PUBLIC_MISMATCH cycle %llu\\n",(unsigned long long)cyc);exit(91);}\n if(!getenv("SYS_REG_PUBLIC_ONLY")&&top->state_diff){printf("SYS_REG_STATE_MISMATCH cycle %llu\\n",(unsigned long long)cyc);exit(92);}')
cpp=cpp.replace('if (top->m_we) rmem.write(a, top->m_wdata, top->m_size32);','if(top->m_unit){u32 d=rmem.read(a,true);rmem.write(top->m_dst,d,true);top->m_rdata=d;}else if (top->m_we) rmem.write(a, top->m_wdata, top->m_size32);')
extra=r'''
    // Additional actual CPU/DMA arbitration and warm-reset/import consumers.
    auto raw=[&](bool req=false,bool cpu=false,bool write=false,unsigned addr=0,unsigned wd=0){
      top->io_req=req;top->io_we=write;top->io_cpu=cpu;top->io_addr=addr>>2;top->io_be=15;top->io_wdata=wd;top->tmr_oh=0;
      top->m_ack=top->m_req&&(cyc%3!=0);top->m_rdata=0xabcd1234u^(unsigned)cyc;eval_edge();
    };
    auto setup=[&](){raw(true,0,1,0xb0,0x02010000);raw(true,0,1,0xb4,0x02210000);raw(true,0,1,0xb8,0x84000040);};
    // Stop any retained enabled GX channel without altering helper state.
    for(unsigned c=0;c<4;c++){raw(true,0,1,0xb8+12*c,0);raw(true,1,1,0xb8+12*c,0);}
    for(unsigned z=0;z<32;z++)raw();
    setup();
    // Repeated validCPU reads hold DMA's register grant, then release it.
    for(unsigned z=0;z<20;z++)raw(true,0,0,0xb8,0);
    for(unsigned z=0;z<2000;z++)raw(z%3==0,0,0,0xb0,0);
    top->rst=1;raw();raw();top->rst=0;for(unsigned z=0;z<8;z++)raw();
    top->clk=0;top->eval();top->do_import=1;top->eval();top->do_import=0;top->eval();
    raw(true,0,0,0xb0,0); // first public CPU consumer, no settling edge
    raw(true,0,1,0xb8,0x84000040);for(unsigned z=0;z<3000;z++)raw(); // DMA uses restoredSAD+DAD; onlyCNT trigger is rewritten
    printf("SYS_REG_COVERAGE reads%u writes%u dma_loads%u arb_stalls%u collisions%u imports%u\n",top->reg_reads,top->reg_writes,top->dma_loads,top->arb_stalls,top->collisions,top->imports);
    if(!top->arb_stalls||!top->collisions||!top->dma_loads||top->imports!=1)exit(93);
'''
cpp=cpp.replace('    if (unit_count) printf(',extra+'\n    if (unit_count) printf(');(D/'tb_sys.cpp').write_text(cpp)
vendor=Path('build/tools/quartus-lite/25.1/quartus/eda/sim_lib/altera_mf.v');shutil.copy2(vendor,D/'altera_mf.v')
m={'baseline':BASE,'source_parent':subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),'cap_bytes':150*1024*1024,'free_floor':1024*1024*1024,'sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest()for p in D.iterdir()if p.is_file()and p.name!='input.json'}};(D/'input.json').write_text(json.dumps(m,indent=2)+'\n');print('PREPARED',D)
