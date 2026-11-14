#!/usr/bin/env python3
"""Elaborate complete replacement/control and list real state/clock domains.

Unmapped cell/FF counts are structural evidence, never native ALM/STA credit.
"""
import pathlib,subprocess,os,fcntl,json,hashlib,shutil,collections
os.setpriority(os.PRIO_PROCESS,0,10)
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-shared-native';S=D/'source'
H=lambda b:hashlib.sha256(b).hexdigest();r={}
# Exact original baseline, with all production CPU/cache features retained.
B=D/'control';B.mkdir(exist_ok=True)
for n in ['arm_pkg','arm_regfile','arm_mul','arm_thumb','arm_core','arm9_core','arm7_ds','arm9_ram','arm9_mem','arm_cpu']:
 (B/(n+'.sv')).write_bytes(subprocess.check_output(['git','show','232c26ac:rtl/arm/'+n+'.sv'],cwd=W))
header=(S/'arm_cpu_shared.sv').read_text().split(' logic[1:0]ni_req,',1)[0].replace('module arm_cpu_shared #','module arm_cpu_control #',1)
body=''' arm_cpu #(.RF_STYLE("MLAB"),.A9_RF("MLAB"),.ARM9_WAYS(2),.ARM9_BURST(1),.ARM9_EVB(1),.ARM9_EVBW(0),.ARM9_EARLYD(1),.A9_XD(2),.A9_XI(1),.A9_OPT(1711268835),.A9_CORE(1),.A7_DS(1),.A9_SOLO(1),.SLOW(1)) original(.clk(clk_sys),.*);
endmodule
'''
(B/'control_top.sv').write_text(header+body)
Y=pathlib.Path.home()/'Git/openfpga-PlayStation/build/tools/oss-cad-suite/bin/yosys'
lock=open(pathlib.Path.home()/'.cache/nds-sim-build.lock','a');fcntl.flock(lock,fcntl.LOCK_EX)
policy=json.loads(pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/host-disk-admission.json').read_text());mi=dict(x.split(':',1)for x in pathlib.Path('/proc/meminfo').read_text().splitlines());r['guard']={'NI':os.getpriority(os.PRIO_PROCESS,0),'RAM':int(mi['MemAvailable'].split()[0])*1024,'disk':shutil.disk_usage(W).free,'growth':policy['default_build_peak_new_bytes'],'floor':policy['floor_bytes'],'mutex':True};assert r['guard']['RAM']>=12*(1<<30)and r['guard']['disk']-r['guard']['growth']>=r['guard']['floor']
for tag,top,files in [('replacement','arm_cpu_shared',[S/(n+'.sv')for n in ['arm_pkg','arm_regfile','arm_mul','arm_thumb','arm9_ram','arm9_mem','arm_shared_core','arm_dual_shared','arm_cpu_shared']]),('control','arm_cpu_control',list(B.glob('*.sv')))]:
 script='read_slang --allow-use-before-declare --top '+top+' '+' '.join(map(str,files))+'; proc; opt; opt_clean; scc; stat; write_json '+str(D/(tag+'-synthesis.json'))
 with(D/(tag+'-synthesis.log')).open('w')as f:p=subprocess.run([Y,'-Q','-T','-m','slang','-p',script],stdout=f,stderr=subprocess.STDOUT)
 assert p.returncode==0,(tag,(D/(tag+'-synthesis.log')).read_text()[-1800:])
 text=(D/(tag+'-synthesis.log')).read_text();assert 'Found 0 SCCs.'in text,(tag,text[-2000:])
 m=json.loads((D/(tag+'-synthesis.json')).read_text())['modules'][top];counts=collections.Counter(c['type']for c in m['cells'].values());regs=[]
 for name,c in m['cells'].items():
  if 'dff'in c['type']:
   width=c['parameters'].get('WIDTH','0');width=int(width,2)if isinstance(width,str)else width
   regs.append({'name':name,'kind':c['type'],'bits':width,'clock':c['connections'].get('CLK',[])})
 r[tag]={'source_sha256':{p.name:H(p.read_bytes())for p in files},'unmapped_cells':sum(counts.values()),'cell_types':dict(counts),'FF_bits':sum(x['bits']for x in regs),'memories':m.get('memories',{}),'clocked_registers':regs,'SCC':0}
 if tag=='replacement':assert not any('g_a9c' in n or'g_a7ds'in n for n in m.get('netnames',{})),'duplicate original CPU engines'
(D/'frontend-result.json').write_text(json.dumps(r,indent=2)+'\n')
print({tag:{k:r[tag][k]for k in ['unmapped_cells','FF_bits','SCC']}for tag in ['replacement','control']})
