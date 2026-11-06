#!/usr/bin/env python3
"""One Desktop slot: semantic LDM metadata, unchanged observable CPU behavior."""
from pathlib import Path
import hashlib,importlib.util,json,os,re,resource,shutil,struct,subprocess,sys,time
ROOT=Path(__file__).resolve().parents[3];BASE='897170f150ea4494f0681c2cae496e4e15168b8a';os.chdir(ROOT)
G=ROOT/'build/ldm-meta';G.mkdir(parents=True,exist_ok=True);os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0));assert '--allocated'in sys.argv
sys.path.insert(0,str(ROOT/'sim/arm/ncnb_store'));from worker_guard import guard,wait_owned
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest();FILES='arm_pkg arm_regfile arm_mul arm_thumb arm_core arm9_ram arm9_mem arm_cpu'.split();V='build/tools/oss-cad-suite/bin/verilator'
(G/'LEASE_READY').unlink(missing_ok=True);(G/'supervisor.json').write_text(json.dumps({'pid':os.getpid(),'host':'Desktop','NI':10,'slots':1})+'\n');print((G/'supervisor.json').read_text(),flush=True)
while '--await-release'in sys.argv and not(G/'LEASE_READY').exists():time.sleep(.2)
def record(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def call(cmd,log,allowed=False):
 guard();cmd=list(map(str,cmd));record(log.with_suffix('.command.json'),cmd)
 with log.open('w')as out:
  p=subprocess.Popen(cmd,stdout=out,stderr=subprocess.STDOUT)
  with(G/'processes.jsonl').open('a')as q:q.write(json.dumps({'pid':p.pid,'NI':os.getpriority(os.PRIO_PROCESS,p.pid),'argv':cmd,'log':str(log)})+'\n')
  print(p.pid,str(log),flush=True);rc=wait_owned(p)
 if not allowed:assert rc==0,(rc,str(log),log.read_text()[-2000:])
 return rc,log.read_text()
source={}
for name in ['before','candidate','mutant']:
 d=G/name;d.mkdir(exist_ok=True)
 for file in FILES:
  b=subprocess.check_output(['git','show',BASE+':rtl/arm/'+file+'.sv'])if name=='before'else(ROOT/'rtl/arm'/(file+'.sv')).read_bytes()
  if name=='mutant'and file=='arm9_mem':
   a=b'w_ldm_meta <= d_ldm_meta;';assert b.count(a)==1;b=b.replace(a,b"w_ldm_meta <= 7'd0;")
  p=d/(file+'.sv')
  if p.exists():assert p.read_bytes()==b,('frozen source changed',p)
  else:p.write_bytes(b)
 source[name]={file:sha(d/(file+'.sv'))for file in FILES}
record(G/'sources.json',{'base':BASE,'files':source})
tb=(ROOT/'sim/arm/tb_arm.sv').read_text().replace('      if (dbg_wen) shadow','      if (dut.u_core.rf_we2) shadow[dut.u_core.rf_wa2[5]][dut.u_core.rf_wa2[4:0]] = dut.u_core.rf_wd2;\n      if (dbg_wen) shadow')
tb=tb.replace('.ARM9_WAYS(ARM9_WAYS),','.ARM9_WAYS(ARM9_WAYS), .ARM9_READ_ACK_EARLY(1), .ARM9_NCNB_WAIT(1),')
probe='''
  logic meta_prev=0;logic[6:0]meta_held;logic[31:0]meta_addr;
  always @(posedge clk)if(!rst && $test$plusargs("packets"))begin
   if(b9_req && b9_ack)$display("PACKET %h %b %h %h",b9_addr,b9_we,b9_be,b9_we?b9_wdata:b9_rdata);
`ifdef NEW_META
   if(meta_prev && (!b9_req || dut.b9_ldm_meta!==meta_held || b9_addr!==meta_addr))$fatal(1,"held descriptor changed before actual ACK");
   meta_prev<=b9_req && dut.b9_ldm && !b9_ack;meta_held<=dut.b9_ldm_meta;meta_addr<=b9_addr;
   if(!dut.b9_ldm && dut.b9_ldm_meta!==0)$fatal(1,"descriptor on untagged owner");
   if(b9_req && b9_ack && dut.b9_ldm)$display("META %h %h",b9_addr,dut.b9_ldm_meta);
`endif
  end
'''
tb=tb.replace('endmodule',probe+'\nendmodule');(G/'tb.sv').write_text(tb)
def build(name):
 d=G/name;out=d/'obj';model=out/'Vtb_arm'
 if model.exists():return model
 cc=[V,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb_arm','--Mdir',out,'-GARM9_WAYS=4','-GSLOW=1','-GA9_SOLO=1','-GA9_OPT=461366243','-GEVB=1','-GA9_XD=0','-GA9_XI=0']
 if name!='before':cc+=['+define+NEW_META']
 call(cc+[d/(f+'.sv')for f in FILES]+[G/'tb.sv'],d/'build.log');return model
spec=importlib.util.spec_from_file_location('check',ROOT/'rnd/check_cpu.py');c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
def small(cmd,**kw):return subprocess.run(list(map(str,cmd)),check=True,**kw)
c.run=small
models={name:build(name)for name in ['before','candidate','mutant']}
expected=[]
def group(addr,n,regular,accepted=None):
 for k in range(n if accepted is None else accepted):expected.append((addr+4*k,(64 if k==0 else 0)|(32 if k==n-1 else 0)|((n-1)<<1)|regular))
group(0x024100c0,4,0);group(0x024100d0,4,0)
for form in range(4):group(0x02410040,8,int(form==0))
group(0x0241007c,8,1);group(0x024100a0,2,0);group(0x024100a0,2,0);group(0x02410000,8,0);group(0x02410200,2,0);group(0x02410000,8,0);group(0x02410ff8,8,1,2)
for addr,n in [(0x02410300,2),(0x02410310,1),(0x02410320,4),(0x02410340,1),(0x02410340,1)]:group(addr,n,1)
group(0x02410400,16,0);assert len(expected)==97
record(G/'expected.json',expected)
image=c.assemble((ROOT/'sim/arm/ldm_meta/directed.s').read_text(),G/'directed');(G/'seed.bin').write_bytes(struct.pack('<8192I',*[0x13240000+i for i in range(8192)]));small(['python3','sim/arm/tools/mkhex.py',image,str(G/'directed.bin')+'@0x02000000',str(G/'seed.bin')+'@0x02410000'])
end=next(l.split()[0]for l in subprocess.check_output(['llvm-nm',G/'directed.elf'],text=True).splitlines()if l.endswith(' compare_end'))
def actual(name,img,stem,lat=2,cut=end):
 rc,t=call([models[name],f'+img0={img}','+pc0=02000000','+run=1',f'+blat={lat}','+maxcycles=2000000',f'+trace0={stem}.csv','+packets'],stem.with_suffix('.log'))
 assert 'TEST PASSED'in t and 'timeout'not in t.lower(),(stem,t[-2000:])
 rows=stem.with_suffix('.csv').read_text().splitlines();rows=rows[:next(i for i,l in enumerate(rows)if l.startswith(cut+','))]
 return {'rows':rows,'packets':re.findall(r'^PACKET.*',t,re.M),'metas':[(int(a,16),int(m,16))for a,m in re.findall(r'^META ([0-9a-f]+) ([0-9a-f]+)',t,re.M)],'cycles':re.findall(r'cycles=(\d+)',t)}
results={'base':BASE,'source':source,'models':{n:sha(p)for n,p in models.items()},'focused':{}}
for lat in [0,1,2,9]:
 a=actual('before',image,G/f'before-lat{lat}',lat);b=actual('candidate',image,G/f'candidate-lat{lat}',lat)
 assert a['rows']==b['rows']and a['packets']==b['packets']and a['cycles']==b['cycles'],('observable changed',lat)
 assert b['metas']==expected,('descriptor mismatch',lat,[(i,x,y)for i,(x,y)in enumerate(zip(b['metas'],expected))if x!=y][:6],len(b['metas']))
 results['focused'][str(lat)]={'states':len(a['rows']),'packets':len(a['packets']),'descriptors':len(b['metas']),'cycles':a['cycles'],'cycle_state_packet_exact':True};print('FOCUSED',lat,results['focused'][str(lat)],flush=True)
bad=actual('mutant',image,G/'mutant-lat2',2);assert bad['metas']!=expected and len(bad['metas'])==97
results['mutation']={'caught':True,'kind':'actual WB metadata capture replaced with zero','first_mismatch':next((i,x,y)for i,(x,y)in enumerate(zip(bad['metas'],expected))if x!=y),'architecture_still_passes':True}
record(G/'focused.json',results);print('FOCUSED META PASS; actual dropped-WB descriptor caught',flush=True)
