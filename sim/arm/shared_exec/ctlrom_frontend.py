#!/usr/bin/env python3
"""Complete selected CPU cone accounting; not a native area/timing forecast."""
import pathlib,subprocess,os,fcntl,json,hashlib,shutil,collections,time
os.setpriority(os.PRIO_PROCESS,0,10)
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-ctlrom';S=D/'source';H=lambda b:hashlib.sha256(b).hexdigest();STATUS=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json')
header=(W/'rtl/arm/study/arm_cpu_shared.sv').read_text().split(' logic[1:0]ni_req,',1)[0].replace('module arm_cpu_shared #','module ctlrom_top #',1).replace('clk_sys,clk2,rst','clk_sys,rst')
body=''' arm_cpu_ctlrom #(.CTLROM(1),.RF_STYLE("MLAB"),.A9_RF("MLAB"),.ARM9_WAYS(2),.ARM9_BURST(1),.ARM9_EVB(1),.ARM9_EVBW(0),.ARM9_EARLYD(1),.A9_XD(2),.A9_XI(1),.A9_OPT(1711268835),.A9_CORE(1),.A7_DS(1),.A9_SOLO(1),.SLOW(1)) selected(.clk(clk_sys),.*);
endmodule
'''
(S/'ctlrom_top.sv').write_text(header+body);files=[S/(n+'.sv')for n in ['arm_pkg','arm_regfile','arm_mul','arm_thumb','arm_core','arm7_ds','arm9_ram','arm9_mem','arm_cpu_ctlrom','arm9_core_ctlrom','ctlrom_address','ctlrom_reconstruct','arm9_ctlrom_planes','arm9_ctlrom_packet','ctlrom_top']]
lock=open(pathlib.Path.home()/'.cache/nds-sim-build.lock','a');fcntl.flock(lock,fcntl.LOCK_EX)
mi=dict(x.split(':',1)for x in pathlib.Path('/proc/meminfo').read_text().splitlines());policy=json.loads(pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/host-disk-admission.json').read_text());guard={'NI':os.getpriority(os.PRIO_PROCESS,0),'RAM':int(mi['MemAvailable'].split()[0])*1024,'disk':shutil.disk_usage(W).free,'growth':policy['default_build_peak_new_bytes'],'floor':policy['floor_bytes'],'mutex':True};assert guard['NI']==10 and guard['RAM']>=12*(1<<30)and guard['disk']-guard['growth']>=guard['floor']
Y=pathlib.Path.home()/'Git/openfpga-PlayStation/build/tools/oss-cad-suite/bin/yosys';script='read_slang --allow-use-before-declare --top ctlrom_top '+' '.join(map(str,files))+f'; proc; opt; opt_clean; scc; stat; write_json {D}/full-cone-synthesis.json; memory_dff; opt_clean; write_json {D}/full-cone-readports.json'
with(D/'full-cone-frontend.log').open('w')as log:
 p=subprocess.Popen([Y,'-Q','-T','-m','slang','-p',script],stdout=log,stderr=subprocess.STDOUT)
 s=json.loads(STATUS.read_text());s.update(phase='CTLROM_FULL_CONE_FRONTEND',workers=[{'host':'Desktop','PID':os.getpid(),'NI':10,'peak_new_bytes':4294967296,'job':'ctlrom-fullcone'},{'host':'Desktop','PID':p.pid,'NI':os.getpriority(os.PRIO_PROCESS,p.pid),'job':'Yosys-completeCPU'}],updated_at=time.time());t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(s,separators=(',',':'))+'\n');os.replace(t,STATUS)
 rc=p.wait(timeout=90)
assert rc==0,(D/'full-cone-frontend.log').read_text()[-1800:];assert'Found 0 SCCs.'in(D/'full-cone-frontend.log').read_text()
m=json.loads((D/'full-cone-synthesis.json').read_text())['modules']['ctlrom_top'];assert not any('g_original_decode'in n for n in m['netnames']);regs=[];clocked=collections.Counter()
for name,c in m['cells'].items():
 if'dff'in c['type']:
  v=c['parameters'].get('WIDTH','0');v=int(v,2)if isinstance(v,str)else v;pol=c['parameters'].get('CLK_POLARITY','1');pol=int(pol,2)if isinstance(pol,str)else pol;regs.append({'name':name,'bits':v,'clock':c['connections'].get('CLK',[]),'polarity':pol,'Q':c['connections']['Q']});clocked[str((c['connections'].get('CLK',[]),pol))]+=v
q={b for c in regs for b in c['Q']};state={}
for key in ['token','assert_metadata']:
 n='selected.g_a9c.u_core9.g_ctlrom.controller.'+key;bits=m['netnames'][n]['bits'];state[key]={'declared':len(bits),'live_unique_FF_bits':len(set(bits)&q)}
rm=json.loads((D/'full-cone-readports.json').read_text())['modules']['ctlrom_top'];readports=[]
for n,c in rm['cells'].items():
 if c['type'].startswith('$memrd')and'.banks.rom'in c['parameters'].get('MEMID',''):
  readports.append({'name':n,'type':c['type'],'parameters':c['parameters'],'clock':c['connections'].get('CLK',[])})
r={'not_native_area_or_STA':True,'guard':guard,'RTL_sha256':{p.name:H(p.read_bytes())for p in files},'unmapped_cells':len(m['cells']),'FF_bits':sum(c['bits']for c in regs),'FF_clock_phase_bits':dict(clocked),'token_and_legacy_assert_holds':state,'ROM_memories':{n:v for n,v in m['memories'].items()if'.banks.rom'in n},'all_memories':m['memories'],'ROM_read_ports':readports,'SCC':0,'inactive_original_D_removed':True,'prior_control_from_existing_receipt':{'cells':4994,'FF_bits':2987,'memory_objects':41,'logical_memory_bits':678170},'native_source_price_owned_byRoot':'710bdf3f41c05c6e7e30ee5a273a60961bdab5bd queue8939'}
(D/'full-cone-result.json').write_text(json.dumps(r,indent=2)+'\n');print({k:r[k]for k in ['unmapped_cells','FF_bits','FF_clock_phase_bits','token_and_legacy_assert_holds','SCC']});print('ROM banks',len(r['ROM_memories']),'readports',len(readports))
s=json.loads(STATUS.read_text());s.update(phase='CTLROM_FULL_CONE_FRONTEND_PASS',workers=[],updated_at=time.time());t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(s,separators=(',',':'))+'\n');os.replace(t,STATUS)
