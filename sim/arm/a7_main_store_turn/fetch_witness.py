#!/usr/bin/env python3
"""Passive, source-pinned offset0/8 attribution on the existing physical gate."""
from pathlib import Path
import argparse, hashlib, importlib.util, json, os, re, resource, shutil, struct, subprocess, tarfile, time

args=argparse.ArgumentParser();args.add_argument('--candidate',action='store_true');args.add_argument('--all-main',action='store_true');args.add_argument('--out',type=Path);args.add_argument('--base',default='dbbff07b');args.add_argument('--turn',action='store_true');args.add_argument('--case');args=args.parse_args()
ROOT=Path(__file__).resolve().parents[3];B=args.out.resolve()if args.out else ROOT/('build/a7-if-rejoin-component'if args.candidate else'build/a7-offset8-witness-r2');B.mkdir(exist_ok=True)
prior_inputs=json.loads((B/'inputs.json').read_text())if(B/'inputs.json').exists()else None
os.chdir(ROOT);os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
V='build/tools/oss-cad-suite/bin/verilator'
BASE=args.base;sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def status(phase,pid=None):
 def start(p):
  try:return Path(f'/proc/{p}/stat').read_text().rsplit(')',1)[1].split()[19]
  except FileNotFoundError:return None
 w=dict(host='Desktop',controller=os.getpid(),PID=pid,starttime=dict(controller=start(os.getpid()),PID=start(pid)if pid else None),NI=10,jobs=1,threads=1)
 (B/'worker.json').write_text(json.dumps(dict(phase=phase,**w),indent=2)+'\n')
 p=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPU.json');d=json.loads(p.read_text());d.update(phase=phase,worker=w,evidence=str(B),lease='Desktop1 NI10/j1/t1 active bounded component')
 s=json.dumps(d,indent=2)+'\n';assert len(s.encode())<=2048;q=p.with_suffix('.tmp');q.write_text(s);q.replace(p)
def call(cmd,label):
 cmd=list(map(str,cmd))
 with (B/(label+'.log')).open('w')as f:
  p=subprocess.Popen(cmd,stdout=f,stderr=subprocess.STDOUT);status(label,p.pid)
  with(B/'processes.jsonl').open('a')as q:q.write(json.dumps(dict(PID=p.pid,controller=os.getpid(),starttime=Path(f'/proc/{p.pid}/stat').read_text().rsplit(')',1)[1].split()[19],argv=cmd,NI=os.getpriority(os.PRIO_PROCESS,p.pid),time=time.time()))+'\n')
  print(label,'PID',p.pid,flush=True);rc=p.wait()
 text=(B/(label+'.log')).read_text();assert rc==0,(label,text[-2200:]);return text
rels=['rtl/arm/arm_pkg.sv','rtl/arm/arm7_ds.sv','rtl/arm/arm_thumb.sv','rtl/ds/nds_arm7_port.sv','rtl/ds/nds_fabric.sv','rtl/ds/nds_mr_arb.sv','rtl/ds/nds_lcache.sv','rtl/ds/nds_ram.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/gpu3d/gpu3d_ram.sv','rtl/mem/psx_pq_psram.sv','rtl/pocket/nds_psram.sv','sim/phase1/cram_model.sv','sim/phase1/sim_prims.sv']
S=B/'source';S.mkdir(exist_ok=True)
for rel in rels:
 raw=(ROOT/rel).read_bytes()
 if not(args.candidate and rel=='rtl/ds/nds_arm7_port.sv'):assert raw==subprocess.check_output(['git','show',BASE+':'+rel])
 (S/Path(rel).name).write_bytes(raw)
for name,kind in [('arm7_ds','reference_arm7_ds'),('nds_arm7_port','old_nds_arm7_port'),('nds_psram','old_nds_psram')]:
 rel=next(r for r in rels if Path(r).name==name+'.sv');raw=subprocess.check_output(['git','show',BASE+':'+rel]);needle=('module '+name).encode();assert raw.count(needle)==1
 (S/(kind+'.sv')).write_bytes(raw.replace(needle,('module '+kind).encode(),1))
packet=ROOT/'docs/results/arm7-data-ack-20261101/proof.tar.gz';assert sha(packet)=='0707d7ca3a716f90dbe0eea6ad968398cd806c22289c77c46a9cd7e794027734'
with tarfile.open(packet)as t:tb=t.extractfile('cpu36/tb.sv').read().decode()
assert tb.count(' arm7_ds\n')==3;tb=tb.replace(' arm7_ds\n',' reference_arm7_ds\n',1)
tb=tb.replace('.DATA_ACK_HANDOFF(1)', '.DATA_ACK_HANDOFF(0)')
if args.candidate:tb=tb.replace(' nds_arm7_port #(', ' nds_arm7_port #(.MAIN_IF_REJOIN(1),')
if args.turn:
 assert args.candidate and BASE!='dbbff07b'
 tb=tb.replace(' nds_arm7_port #(', ' nds_arm7_port #(.MAIN_IF_TURN(1),')
 tb=tb.replace(' old_nds_arm7_port #(', ' old_nds_arm7_port #(.MAIN_IF_REJOIN(1),')
fields={
'cycle':('cycle','d'),'cpu_st':('cpu.st','d'),'ph':('cpu.ph','d'),'pc':('cpu.pc','h'),'pc_f':('cpu.pc_f','h'),
'ins':('cpu.ins','h'),'d_v':('cpu.d_v','d'),'e_v':('cpu.e_v','d'),'e_busy':('cpu.e_busy','d'),'brt':('cpu.brt','d'),'fl_tgt':('cpu.fl_tgt','h'),
'f_rq':('cpu.f_rq','d'),'if_wait':('cpu.if_wait','d'),'ir':('ir','d'),'ia':('ia','h'),'io':('io','d'),'iq':('iq','h'),
'iseq':('iseq','d'),'consume':('iconsume','d'),'redirect':('iredirect','d'),'flow_v':('port7.flow_v','d'),
'flow_a':('port7.flow_a','h'),'flow_left':('port7.flow_left','d'),'flow_qv':('port7.flow_qv','d'),'flow_q':('port7.flow_q','h'),
'flow_sc':('port7.flow_sc','d'),'flow_pv':('port7.flow_pv','d'),'flow_pa':('port7.flow_pa','h'),'flow_pg':('port7.flow_pg','d'),
'if_gen':('port7.if_gen','d'),'rp_v':('port7.rp_v','d'),'rp_i':('port7.rp_i','d'),'rp_a':('port7.rp_a','h'),
'rp_k':('port7.rp_k','d'),'rp_gen':('port7.rp_ifgen','d'),'rp_stale':('port7.rp_stale','d'),'rp_bad':('port7.rp_bad','d'),
'rp_flow':('port7.rp_flow','d'),'rp_il':('port7.rp_il','d'),'il_a0':('port7.il_a[0]','h'),'il_a1':('port7.il_a[1]','h'),
'il_w0':('port7.il_word_v[0]','h'),'il_w1':('port7.il_word_v[1]','h'),'il_flow':('port7.il_flow','h'),
'flow_capture':('port7.flow_capture','d'),'flow_arrive':('port7.flow_arrive','d'),'flow_held':('port7.flow_held','d'),
'flow_turn':('port7.flow_turn','d'),'flow_prefetch':('port7.flow_prefetch','d'),'flow_look':('port7.flow_look','d'),
'fr':('fr','d'),'fn':('fn','d'),'fa':('fa','h'),'ack':('ack','d'),'rv':('rv','d'),'fq':('fq','h'),
'fab_st':('transport.u_fab.st','d'),'fab_grant7':('transport.u_fab.grant[2]','d'),'fab_q7':('transport.u_fab.q7','d'),
'fab_gen':('transport.u_fab.q7_gen','d'),'fab_hit':('transport.u_fab.lb_hit','d'),
'mr_req':('transport.mr_req','d'),'mr_addr':('transport.mr_addr','h'),'mr_ack':('transport.mr_ack','d'),
'mr_rvalid':('transport.mr_rvalid','d'),'phy_busy':('transport.u_phy.busy','d'),'phy_strm':('transport.u_phy.strm','d'),
'phy_word':('transport.u_phy.b_word','h'),'phy_wc':('transport.u_phy.wc_b','d'),'phy_tot':('transport.u_phy.tot','d'),
'phy_if8_valid':('transport.u_phy.if8_valid','d'),'phy_if8_gen':('transport.u_phy.if8_gen','d'),
}
(B/'fields.json').write_text(json.dumps(fields,indent=2)+'\n')
observer='''\n string witness_path;integer witness_fd=0;
 initial if($value$plusargs("offset8_witness=%s",witness_path))begin
 witness_fd=$fopen($sformatf("%s-m%0d.witness.csv",witness_path,MODE),"w");
 $fdisplay(witness_fd,"HEADER");end
 always @(posedge clk)if(witness_fd&&!rst)$fdisplay(witness_fd,"FORMAT",VALUES);
 final if(witness_fd)$fclose(witness_fd);
'''.replace('HEADER',','.join(fields)).replace('FORMAT',','.join('%0'+v[1]for v in fields.values())).replace('VALUES',','.join(v[0]for v in fields.values()))
for module in ['cpu_before','cpu_after']:
 start=tb.index('module '+module+' ');end=tb.index('endmodule',start);tb=tb[:end]+observer+tb[end:]
(B/'tb.sv').write_text(tb)
files=[S/'arm_pkg.sv']+[p for p in sorted(S.glob('*.sv'))if p.name!='arm_pkg.sv']+[B/'tb.sv']
current_inputs={str(p.relative_to(B)):sha(p)for p in files}
(B/'inputs.json').write_text(json.dumps(current_inputs,indent=2)+'\n')
model=B/'obj/Vtb_seq2'
if not(model.exists()and prior_inputs==current_inputs):
 call([V,'--binary','--timing','--assert','+define+A7_FLOW_SOURCE','-j','1','--threads','1','-O2','-Wno-fatal','--top-module','tb_seq2','--Mdir',model.parent,*files],'build')
(B/'model.json').write_text(json.dumps(dict(sha256=sha(model),inputs=current_inputs),indent=2)+'\n')
for p in model.parent.iterdir():
 if p.is_file()and(p.suffix in['.o','.a','.d','.gch']or(p.name.startswith('Vtb')and p.suffix in['.cpp','.h','.mk','.dat'])):p.unlink()
spec=importlib.util.spec_from_file_location('af39',ROOT/'sw/tests/a7fetch39/build.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);blobs,layout=m.captured()
conditions=[('b_s16_o0',1),('b_s16_o8',1),('b_s16_o8',0)]
if args.all_main:conditions=[(c['case'],n)for c in layout['cases']for n in [4,16]]
elif args.case:conditions=[(args.case,1)]
counts=[]
for name,enabled in conditions:
 loops=enabled if args.all_main else 16
 if args.all_main:enabled=0
 c=next(c for c in layout['cases']if c['case']==name);raw=blobs[f'arm7fetch_v1_k{c["id"]:02d}_r0.bin'];checksum=struct.unpack_from('<I',raw,344)[0]
 image=B/(name+'.hex');code=raw[348:348+c['size']];image.write_text(''.join(f'{v:08x}\n'for v in struct.unpack('<1024I',code+bytes(4096-len(code)))))
 stem=B/(name+(f'-n{loops}'if args.all_main else'-on'if enabled else'-off'));entry=c['main_entry']
 cmd=[model,f'+img={image}',f'+entry={entry:x}',f'+source={c["source_entry"]:x}',f'+body={entry+c["source_body"]-c["source_entry"]:x}',f'+size={c["size"]}',f'+sum={checksum}',f'+loops={loops}',f'+trace={stem}',f'+data={stem}','+phase=0']
 if enabled:cmd.append(f'+offset8_witness={stem}')
 text=call(cmd,stem.name);assert'PASS coupled F order pair'in text
 for suffix in['.csv','.data','.fcomp']:assert Path(str(stem)+'-m0'+suffix).read_bytes()==Path(str(stem)+'-m1'+suffix).read_bytes(),(name,suffix)
 if not enabled and not args.all_main:
  for suffix in['.csv','.data','.fcomp']:
   assert Path(str(stem)+'-m1'+suffix).read_bytes()==Path(str(B/(name+'-on'))+'-m1'+suffix).read_bytes()
  lines=lambda x:[s for s in x.splitlines()if s.startswith('PHYS_PASS')]
  assert lines(text)==lines((B/(name+'-on.log')).read_text())
 found=re.findall(r'PHYS_PASS mode(\d+) cycles(\d+) states(\d+) consumes(\d+) branches(\d+) requests(\d+) physical(\d+) discarded_fetch(\d+)',text)
 values={v[0]:dict(zip('cycles states consumes branches requests physical discarded_fetch'.split(),map(int,v[1:])))for v in found};assert len(values)==2
 counts.append(dict(case=name,loops=loops,observer=enabled,log=stem.name+'.log',counts=values));print('ROW',counts[-1],flush=True)
 (B/'runs.json').write_text(json.dumps(counts,indent=2)+'\n')
status('Offset8 witness PASS; source unchanged; analysis next')
print('WITNESS_PASS',len(counts),'windows; full state/F/DATA exact; observer passivity checked when selected',flush=True)
