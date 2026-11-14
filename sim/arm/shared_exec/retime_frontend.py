#!/usr/bin/env python3
"""Complete retimed cone/clock state accounting; reuse existing original frontend."""
import pathlib,subprocess,os,fcntl,json,hashlib,shutil,collections
os.setpriority(os.PRIO_PROCESS,0,10)
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-retimed';S=D/'source';H=lambda b:hashlib.sha256(b).hexdigest()
header=(W/'rtl/arm/study/arm_cpu_shared.sv').read_text().split(' logic[1:0]ni_req,',1)[0].replace('module arm_cpu_shared #','module retimed_top #',1)
body=''' arm_cpu_retimed #(.SHARED_EXEC(1),.RF_STYLE("MLAB"),.A9_RF("MLAB"),.ARM9_WAYS(2),.ARM9_BURST(1),.ARM9_EVB(1),.ARM9_EVBW(0),.ARM9_EARLYD(1),.A9_XD(2),.A9_XI(1),.A9_OPT(1711268835),.A9_CORE(1),.A7_DS(1),.A9_SOLO(1),.SLOW(1)) retained(.clk(clk_sys),.*);
endmodule
'''
p=S/'retimed_top.sv';p.write_text(header+body)
files=[S/(n+'.sv')for n in ['arm_pkg','arm_regfile','arm_mul','arm_thumb','arm_core','arm9_ram','arm9_mem','arm_exec_halfslots','arm9_core_retimed','arm7_ds_retimed','arm_cpu_retimed','retimed_top']]
lock=open(pathlib.Path.home()/'.cache/nds-sim-build.lock','a');fcntl.flock(lock,fcntl.LOCK_EX)
policy=json.loads(pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/host-disk-admission.json').read_text());mi=dict(x.split(':',1)for x in pathlib.Path('/proc/meminfo').read_text().splitlines());guard={'NI':os.getpriority(os.PRIO_PROCESS,0),'RAM':int(mi['MemAvailable'].split()[0])*1024,'disk':shutil.disk_usage(W).free,'growth':policy['default_build_peak_new_bytes'],'floor':policy['floor_bytes'],'mutex':True};assert guard['NI']==10 and guard['RAM']>=12*(1<<30)and guard['disk']-guard['growth']>=guard['floor']
Y=pathlib.Path.home()/'Git/openfpga-PlayStation/build/tools/oss-cad-suite/bin/yosys';script='read_slang --allow-use-before-declare --top retimed_top '+' '.join(map(str,files))+'; proc; opt; opt_clean; scc; stat; write_json '+str(D/'retimed-synthesis.json')
with(D/'retimed-synthesis.log').open('w')as log:p=subprocess.run([Y,'-Q','-T','-m','slang','-p',script],stdout=log,stderr=subprocess.STDOUT)
assert p.returncode==0,(D/'retimed-synthesis.log').read_text()[-2000:];assert'Found 0 SCCs.'in(D/'retimed-synthesis.log').read_text()
m=json.loads((D/'retimed-synthesis.json').read_text())['modules']['retimed_top'];counts=collections.Counter(c['type']for c in m['cells'].values());regs=[]
for name,c in m['cells'].items():
 if'dff'in c['type']:
  v=c['parameters'].get('WIDTH','0');v=int(v,2)if isinstance(v,str)else v;regs.append({'name':name,'kind':c['type'],'bits':v,'clock':c['connections'].get('CLK',[])})
prior=json.loads((W/'build/cpu232-shared-native/frontend-result.json').read_text())['control']
r={'not_native_ALM_or_STA':True,'guard':guard,'source_sha256':{p.name:H(p.read_bytes())for p in files},'unmapped_cells':sum(counts.values()),'FF_bits':sum(c['bits']for c in regs),'SCC':0,'cell_types':dict(counts),'clocked_registers':regs,'prior_control':{'unmapped_cells':prior['unmapped_cells'],'FF_bits':prior['FF_bits'],'source_sha256':prior['source_sha256']},'memories':m.get('memories',{})}
r['FF_bits_by_clock']={}
for port in ['clk_sys','clk2']:
 bits=m['ports'][port]['bits'];r['FF_bits_by_clock'][port]=sum(c['bits']for c in regs if c['clock']==bits)
r['shared_resource_output_drivers']={}
for short in ['rot_r','ar','lr']:
 bits=set(m['netnames']['retained.g_shared_exec.u_exec.'+short]['bits']);drivers={}
 for n,c in m['cells'].items():
  for k,v in c['connections'].items():
   if c['port_directions'].get(k)=='output'and bits.intersection(v):drivers[n]=c['type']
 r['shared_resource_output_drivers'][short]=drivers
shape=lambda mem:collections.Counter((x['width'],x['size'],x['start_offset'],x['attributes'].get('ramstyle'))for x in mem.values())
assert shape(r['memories'])==shape(prior['memories'])
r['memory_shapes_match_control']=True;r['total_memory_bits']=sum(x['width']*x['size']for x in r['memories'].values())
(D/'frontend-result.json').write_text(json.dumps(r,indent=2)+'\n');print({k:r[k]for k in ['unmapped_cells','FF_bits','SCC']});print('retained prior control',r['prior_control']['unmapped_cells'],r['prior_control']['FF_bits'])
