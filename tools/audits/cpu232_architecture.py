#!/usr/bin/env python3
"""Source/report-only CPU storage feasibility audit. No RTL/synthesis/sim/fit."""
import os
os.setpriority(os.PRIO_PROCESS,0,10)
import argparse,hashlib,itertools,json,pathlib,re,subprocess,tarfile,io
W=pathlib.Path(__file__).resolve().parents[2];ap=argparse.ArgumentParser();ap.add_argument('--price-dir',type=pathlib.Path);ap.add_argument('--refs',type=pathlib.Path);ap.add_argument('--out',type=pathlib.Path,default=W/'build/cpu232-architecture');a=ap.parse_args();O=a.out;O.mkdir(parents=True,exist_ok=True)
P=a.price_dir or W/'docs/results/rc053-rhit-price-20261110'
if not P.exists():P=W.parent/'NDS_Pocket/docs/results/rc053-rhit-price-20261110'
V=a.refs or W/'references'
if not V.exists():V=W.parent/'NDS_Pocket/references'
H=lambda b:hashlib.sha256(b).hexdigest();R=json.loads((P/'result.json').read_text());raw=(P/'evidence.tar.gz').read_bytes();assert H(raw)==R['archive_sha256']
with tarfile.open(fileobj=io.BytesIO(raw),mode='r:gz') as t:F={n:t.extractfile(n).read() for n in ['2177/apf_top.fit.rpt','2177/apf_top.map.rpt','binding.json']}
for n,b in F.items():assert H(b)==R['members'][n];(O/pathlib.Path(n).name).write_bytes(b)
f=F['2177/apf_top.fit.rpt'].decode('latin1');m=F['2177/apf_top.map.rpt'].decode('latin1');REF='232c26ac0ee2a23abffa6397c69802badee0e999'
paths=['rtl/arm/arm9_core.sv','rtl/arm/arm9_mem.sv','rtl/arm/arm9_ram.sv','rtl/arm/arm7_ds.sv','rtl/arm/arm_cpu.sv','rtl/arm/cpu_domain.sv','rtl/arm/arm_core.sv','rtl/arm/arm_pkg.sv','rtl/pocket/core_top_ds.sv','rtl/pocket/nds_pll_ds.sv'];sources={}
for rel in paths:
 b=subprocess.check_output(['git','show',REF+':'+rel],cwd=W);assert b==(W/rel).read_bytes(),rel;p=O/'source'/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b);sources[rel]=H(b)
def section(text,name):
 s=text.index('; '+name);e=text.find('\n\n',s+300);return text[s:e]
def rows(text):return [[x.strip() for x in line.split(';')][1:-1] for line in text.splitlines() if line.startswith(';')]
fitrows=rows(section(f,'Fitter Resource Utilization by Entity'));maprows=rows(section(m,'Analysis & Synthesis Resource Utilization by Entity'));cpu={}
for name in ['cpu_domain:u_cpud','arm_cpu:g_one.u_cpu','arm9_core:g_a9c.u_core9','arm7_ds:g_a7ds.u_a7','arm9_mem:u_mem9']:
 fr=next(r for r in fitrows if r and r[0]=='|'+name+'|');mr=next(r for r in maprows if r and r[0]=='|'+name+'|');cpu[name]={'fitter_raw':fr,'synthesis_raw':mr,'needed_inclusive':float(fr[1].split()[0]),'needed_own':float(re.search(r'\(([^)]+)\)',fr[1])[1]),'fitter_FF_inclusive':int(fr[7].split()[0]),'fitter_FF_own':int(re.search(r'\(([^)]+)\)',fr[7])[1])}
ramrows=rows(section(f,'Fitter RAM Summary'));head=next(r for r in ramrows if r and r[0]=='Name');ram=[dict(zip(head,r)) for r in ramrows if r and 'arm9_mem:u_mem9|arm9_ram:' in r[0]]
cache=[r for r in ram if re.search(r'arm9_ram:dway\[[01]\]\.u_[di]\|',r['Name'])];assert len(cache)==16;assert sum(int(r['M10K blocks']) for r in cache)==32;assert sum(int(r['Implementation Bits']) for r in cache)==262144
payload=[r for r in fitrows if r and re.match(r'\|arm9_ram:dway\[[01]\]\.u_[di]\|$',r[0])];assert len(payload)==4 and all(r[1]=='0.0 (0.0)' for r in payload)
dtcm_lanes=[r for r in ram if 'arm9_ram:u_dtcm|' in r['Name']];assert len(dtcm_lanes)==4 and all(r['Implementation Port A Depth']=='4096' and r['Implementation Port A Width']=='8' and r['M10K blocks']=='4' for r in dtcm_lanes)
removed=section(m,'Registers Removed During Synthesis');pruned={}
for name in ['eu.pc','m_pc','w_pc']:
 bits=set()
 for r in rows(removed):
  if r and 'arm9_core:g_a9c.u_core9|'+name+'[' in r[0]:
   for p in r[0].rsplit('[',1)[1].rstrip(']').split(','):
    if '..' in p:lo,hi=map(int,p.split('..'));bits.update(range(min(lo,hi),max(lo,hi)+1))
    else:bits.add(int(p))
 assert bits==set(range(32)),name;pruned[name]=sorted(bits)
params={}
for name in ['A9_OPT','A9_XD','A9_XI','ARM9_WAYS','CPU_FAST']:
 vals=sorted(set(int(x) for x in re.findall(r'^;\s*'+name+r'\s*;\s*(\d+)\s*;',m,re.M)));params[name]=vals
assert params=={'A9_OPT':[1711268835],'A9_XD':[2],'A9_XI':[1],'ARM9_WAYS':[2],'CPU_FAST':[0]}
opt=params['A9_OPT'][0];flags={n:bool(opt&(1<<b)) for n,b in [('PF',4),('ERI',22),('ERD',23),('HUM',29),('CWF',30)]};assert flags=={'PF':False,'ERI':True,'ERD':True,'HUM':True,'CWF':True}
core=(W/'rtl/arm/arm9_core.sv').read_text();assert 'logic [58:0] q_head;' in core and 'q_tail [0:2]' in core and 'q_tail_read' in core
# Contract witness uses actual enabled HUM branch: unrelated-set cached load,
# simultaneous I hit and accepted D fill write. It is not a reset-reachability run.
witness={'st':'S_FILL','dp_kind':'DK_FILL','dp_v':1,'k':3,'b_ack':1,'f_req':1,'I_hit':1,'busy_i':0,'col_i':0,'wq_e':1,'w_we':0,'wd_cach':1,'wd_hit':1,'D_read_set':17,'D_fill_set':3,'I_read_set':26,'read_word':5,'I_word':2}
operations=[{'name':'I read both ways','row':(26<<3)|2,'read_bits':64},{'name':'D HUM read both ways','row':(1<<11)|(17<<3)|5,'read_bits':64},{'name':'D fill write selected way','row':(1<<11)|(3<<3)|3,'write_bits':32,'byte_enables':8}];assert len({x['row'] for x in operations})==3
assignments=[]
for ports in itertools.product(range(2),repeat=3):
 valid=all(sum(p==port for p in ports)<=1 for port in range(2));assignments.append({'ports':ports,'valid':valid})
assert not any(x['valid'] for x in assignments)
vendors={}
for repo,rels in {'NDS4MiSTer':['rtl/nds_nitro_arm9_adapter.vhd','third_party/Nitro_DarkSide/SOURCE.md','third_party/Nitro_DarkSide/LICENSE.md','third_party/Nitro_DarkSide/rtl/nds_cache9.vhd','third_party/Nitro_DarkSide/rtl/nds_cpu9.vhd']}.items():
 sha=subprocess.check_output(['git','-C',str(V/repo),'rev-parse','HEAD'],text=True).strip();assert sha=='569875a7fe650c28b7af4c760dc136b46af58828'
 for rel in rels:
  b=(V/repo/rel).read_bytes();assert b==subprocess.check_output(['git','-C',str(V/repo),'show',sha+':'+rel]);p=O/'upstream'/repo/rel;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b);vendors[repo+'/'+rel]={'commit':sha,'sha256':H(b)}
prior=subprocess.check_output(['git','show','f8c27307:docs/results/rc053-capacity-bound-20261109/README.md'],cwd=W);(O/'prior-capacity-disposition.md').write_bytes(prior)
result={'source':REF,'kind':'SOURCE_REPORT_ONLY_NO_RTL_OR_RUNS','fit2177':R['fits']['2177'],'fit_report_sha256':H(F['2177/apf_top.fit.rpt']),'map_report_sha256':H(F['2177/apf_top.map.rpt']),'source_sha256':sources,'cpu':cpu,'params':params,'flags':flags,'pruned_PC':pruned,'payload_entity_rows':payload,'RAM_rows':ram,'upstream':vendors,'prior_disposition_sha256':H(prior),'candidate':{'name':'one two-port64bit pooled I/D cache-payload store','layout':'4096rows x64, cache-kind1+set8+word3; both ways per row','payload_bits_retained':262144,'native_8bit_lane_request_equivalent':{'before':32,'after':8*4,'new_primitive_mode_measured':False},'target_payload_needed_ALM_before':0.0,'credited_ALM_saving':0,'credited_RAM_saving':0,'credited_DSP_saving':0,'witness':witness,'simultaneous_operations':operations,'two_port_assignments':assignments,'necessary_SYS_ports':3,'offered_SYS_ports':2,'verdict':'REJECT under original service/deadline contract; no large priced control cone removed','clock_variant':'2xSYS only shifts the problem into half-cycle address/read/write/hold ownership; actual FAST7.458ns, SYS14.917ns, no STA. Not a demonstrated infeasibility of every pumped architecture.','retained_costs':['Two independent32bit late-way result muxes; packed tags/dirty/MPU/replacement/store/eviction controls.','64bit row write with8 byte enables, I/D physical ownership, independent maintenance/fill/read address association.','If ports are reused before the SYS consumer: hold raw both-way results128bits, or select ways before capture and hold64bits. The latter moves both late-tag/way decisions before the chosen capture edge. Native hold realization/clocking unproved; no newFF or savings claim.','Pooling payload alone does not remove the901.6ownALM controller. A complete replacement must reprice that controller and all mux/reconstruction costs.'],'remaining_general_step':'A different complete controller/state architecture with explicit early-restart/HUM/TCM/MPU/store/maintenance service and measured complete-cone reduction; no metadata/RF/rotator resurrection or baseline repeat.'}}
result['candidate']['mux_state_budget']=[
 {'item':'Retained payload','count':262144,'unit':'data bits','status':'no removal'},
 {'item':'I/D response way selection','count':64,'unit':'2:1 selected output bits (2x32)','status':'retained; way remains late'},
 {'item':'Pool row address','count':12,'unit':'bits per access','status':'kind1+set8+word3; three independent rows in witness'},
 {'item':'Pool write bus','count':64,'unit':'bits with8 byte-enable lanes','status':'one selected32bit way; ownership/byte masks retained'},
 {'item':'Partial-store forwarding','count':32,'unit':'merge output bits with4 byte masks','status':'retained; same address/way ownership still required'},
 {'item':'FAST raw read-result hold option','count':128,'unit':'logical data bits (2x64 raw ways)','status':'ports reused before CPU consumer; native realization unproved, not128newFF claim'},
 {'item':'FAST selected read-result hold option','count':64,'unit':'logical data bits (2x32 selected)','status':'requires both late-tag/way decisions before capture; native realization and half-cycle path unproved'},
 {'item':'FAST address phase selection','count':24,'unit':'minimum2:1 address-mux output bits (2x12)','status':'per port read-vs-write phase; enables/reset/control extra unpriced'},
 {'item':'Dynamic controller retained','count':901.6,'unit':'own neededALM baseline wholearm9_mem','status':'touched subset not isolated; payload deletion cannot credit whole controller'}]
(O/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'cpu':{k:{n:v[n] for n in ['needed_own','needed_inclusive','fitter_FF_own']} for k,v in cpu.items()},'candidate':result['candidate']['verdict'],'ports':'3required/2offered','credit':0},indent=2))
