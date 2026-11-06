#!/usr/bin/env python3
"""Affected fixed-port cull cache caller, one D1."""
import datetime,gzip,hashlib,json,os,re,resource,subprocess
from pathlib import Path
R=Path(__file__).resolve().parents[3];B=R/'build/cull-mlab25/caller';B.mkdir(parents=True,exist_ok=True)
S=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Geometry.json');V='build/tools/oss-cad-suite/bin/verilator';BASE='9002ba2590ec05f2d9054dfb9625c1297da78cf5';DONOR='f075fd5421dbd5ce12ac17116b76dd32900ed635'
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
def old(ref,path):return subprocess.check_output(['git','show',ref+':'+path],cwd=R)
meta=json.loads(old(DONOR,'docs/results/geometry-shared4-prototype20-20261103/initial/prepare.json'));files=[];hashes={}
for name in meta['candidate']:
 data=old(BASE,'rtl/gpu3d/'+name).decode();data=re.sub(r'\bgpu3d_(\w+)\b',r'ref_gpu3d_\1',data);(B/('ref_'+name)).write_text(data);files.append(B/('ref_'+name));current=(R/'rtl/gpu3d'/name).read_bytes();(B/name).write_bytes(current);files.append(B/name);hashes[name]=hashlib.sha256(current).hexdigest()
wrapper=gzip.decompress(old(DONOR,'docs/results/geometry-shared4-prototype20-20261103/initial/observer.sv.gz')).decode();assert wrapper.count('.FF(1)')==3;wrapper=wrapper.replace('.FF(1)', '.GX_CLIP_STORE_PUMP(1),.FF(1)');wrapper=wrapper.replace('.GX_CLIP_SHARED4(0)', '.GX_CULL_MLAB(0)').replace('.GX_CLIP_SHARED4(1)', '.GX_CULL_MLAB(1)').replace('.g_shared4.u_shared','');hook=''
for name in ['before','off','on']:
 eng='dut_'+name+'.u_eng';pu=eng+'.g_pu'
 hook+=f'`define E {eng}\n`define P {pu}\n'
 hook+='always @(posedge clk)if(!rst)begin\n'
 hook+=f'if(`P.c_st==3)begin $write("OP,%0d,dut_{name},%0d,%0d,%0d,%0d",cy,case_id,`P.c_g0,`P.c_g1,`P.c_g2);'
 if name=='before':
  for reader in range(3):
   for field in ['cpx','cpy','cpw']:hook+=f'$write(",%08x",`P.{field}[`P.c_g{reader}]);'
 else:hook+='for(integer r=0;r<3;r++)for(integer c=0;c<3;c++)$write(",%08x",`P.cull_operand[r][c]);'
 hook+='$write("\\n");end\n'
 hook+=f'if(`P.c_st==8)$display("CO,%0d,dut_{name},%0d,%0d,%0d,%0d",cy,case_id,`P.c_face,`P.c_rej,`E.pk_go);\nend\n`undef E\n`undef P\n'
wrapper=wrapper.replace('endmodule',hook+'\nendmodule');(B/'observer.sv').write_text(wrapper)
cpp=old(DONOR,'docs/results/geometry-shared4-prototype20-20261103/initial/caller.cpp').decode();assert cpp.count('p<2')==1;cpp=cpp.replace('p<2','p<4');(B/'caller.cpp').write_text(cpp)
cmd=[V,'--cc','--exe','--build','--build-jobs','1','-j','1','--threads','1','--assert','-Wno-fatal','-MAKEFLAGS','VM_PARALLEL_BUILDS=0','--Mdir',str(B/'obj'),'--top-module','tb_public_budget','-CFLAGS','-std=c++20 -O1']+list(map(str,files+[B/'observer.sv',B/'caller.cpp']))
rec={'base':BASE,'donor_inputs':DONOR,'source_sha256':hashes,'controller_PID':os.getpid(),'command':cmd,'scope':'Affected fixed-port cull cache only; productionbefore/off/on, four polygon kinds and fullwidth adversarial cases','stages':[]}
def run(label,command):
 with(B/(label+'.log')).open('w')as f:
  p=subprocess.Popen(command,cwd=R,stdout=f,stderr=subprocess.STDOUT);d=json.loads(S.read_text());d['phase']='D1 cull25 caller '+label;d['worker']={'active':True,'host':'Desktop','PID':os.getpid(),'child_PID':p.pid,'lease':'D1 Root retained','nice':10,'jobs':1,'threads':1};d['updated_at']=datetime.datetime.now(datetime.timezone.utc).isoformat();t=S.with_suffix('.Geometry25.tmp');text=json.dumps(d,separators=(',',':'))+'\n';assert len(text.encode())<=2048;t.write_text(text);t.replace(S);stage={'label':label,'PID':p.pid};rec['stages'].append(stage);(B/'execution.json').write_text(json.dumps(rec,indent=2)+'\n');stage['exit']=p.wait();(B/'execution.json').write_text(json.dumps(rec,indent=2)+'\n');assert stage['exit']==0,(B/(label+'.log')).read_text()[-2500:]
run('build',cmd);run('positive',[str(B/'obj/Vtb_public_budget')]);rows=[x.split(',')for x in(B/'positive.log').read_text().splitlines()];assert not any(x[0]=='DIFF'for x in rows)
checks={}
for tag in ['CAP','RH','RC','NN','END','OP','CO']:
 d={n:[x[:2]+x[3:]for x in rows if len(x)>3 and x[0]==tag and x[2]==n]for n in ['dut_before','dut_off','dut_on']};count=len(d['dut_before']);assert count>0;assert d['dut_before']==d['dut_off']==d['dut_on'],tag;checks[tag]=count
from collections import defaultdict
rf={n:defaultdict(list)for n in ['dut_before','dut_off','dut_on']}
for x in rows:
 if x[0]=='RF':rf[x[2]][tuple(x[3:5])].append(x[5])
assert rf['dut_before']==rf['dut_off']==rf['dut_on']
rec['result']={'qualified_dates_values':checks,'RF_writes':sum(map(len,rf['dut_before'].values())),'RF_version_streams':len(rf['dut_before']),'public_diffs':0,'verdict':'PASS affected cullcache operands/outcomes/order/dates; no area/STA claim'};(B/'execution.json').write_text(json.dumps(rec,indent=2)+'\n');d=json.loads(S.read_text());d['worker']['active']=False;d['phase']='cull25 caller operands/outcomes PASS; result aggregation next';t=S.with_suffix('.Geometry25.tmp');t.write_text(json.dumps(d,separators=(',',':'))+'\n');t.replace(S);print(rec['result'],flush=True)
