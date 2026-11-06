#!/usr/bin/env python3
"""Measure an unpriced finish/prepare/commit CPU trial on frozen P7/transport."""
from pathlib import Path
import argparse, csv, datetime, hashlib, json, os, re, resource, shutil, subprocess, time
from trial import patch

R = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--previous', type=Path, default=R/'build/a7-mul-local/attempt1')
p.add_argument('--mutation', choices=['none', 'early-internal', 'early-commit'], default='none')
p.add_argument('--reuse-model', type=Path, help='reuse a source/hash-identical completed component build')
p.add_argument('--verilator', default='build/tools/oss-cad-suite/bin/verilator')
a = p.parse_args()
D = a.output.resolve()
D.mkdir(parents=True, exist_ok=False)
S = D/'source'; S.mkdir()
I = D/'inputs'; shutil.copytree(a.previous/'inputs', I)
os.setpriority(os.PRIO_PROCESS, 0, 10)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
resource.setrlimit(resource.RLIMIT_CPU, (240, 240))
resource.setrlimit(resource.RLIMIT_AS, (4*1024**3, 4*1024**3))
resource.setrlimit(resource.RLIMIT_FSIZE, (128*1024**2, 128*1024**2))
sha = lambda b: hashlib.sha256(b).hexdigest()
start = lambda pid: Path('/proc', str(pid), 'stat').read_text().rsplit(')', 1)[1].split()[19]
prior = json.loads((a.previous/'results.json').read_text())
layout_path = Path('/home/user/Git/NDS_Pocket/build/coordinator/a7mulmix-dslite-20261102/layout.json')
layout = json.loads(layout_path.read_text())
(I/'layout.json').write_bytes(layout_path.read_bytes())
ds = json.loads(layout_path.with_name('validation.json').read_text())
result = dict(source=subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),
              previous_model=prior['model_SHA256'], previous_source=prior['source'], mutation=a.mutation,
              controller=os.getpid(), stages=[], rows=[], source_SHA256={},
              caps=dict(NI=10, jobs=1, threads=1, CPU_seconds=240, AS_bytes=4*1024**3),
              scope='Test-only phase mapping: first internal START waits for qualified F finish; prepared next address is not a memory request. No wait constants/P7/fabric edit. DS timing remains an independent gate.')
def save(): (D/'results.json').write_text(json.dumps(result, indent=2)+'\n')
status_file = Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPU.json')
def status(phase, proc=None):
    q = json.loads(status_file.read_text())
    q.update(updated_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), phase=phase,
             worker=dict(host='Desktop', active=bool(proc), controller=os.getpid(), PID=proc.pid if proc else None,
                         starttime=start(proc.pid) if proc else None, NI=10, jobs=1 if proc else 0, threads=1 if proc else 0))
    temp = status_file.with_name('CPU.json.tmp.'+str(os.getpid()))
    temp.write_text(json.dumps(q, indent=2)+'\n'); temp.replace(status_file)
def call(command, tag, timeout, expected=0):
    begin = time.monotonic()
    with (D/(tag+'.log')).open('w') as f:
        proc = subprocess.Popen(list(map(str,command)), cwd=R, stdout=f, stderr=subprocess.STDOUT)
        row = dict(tag=tag, PID=proc.pid, starttime=start(proc.pid), command=list(map(str,command)))
        result['stages'].append(row); save(); status(tag,proc)
        print(tag,proc.pid,flush=True)
        try: row['exit'] = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.terminate(); row['exit']=proc.wait(timeout=10); row['timeout']=True
    row.update(reaped=True,wall_seconds=round(time.monotonic()-begin,3)); save(); status(tag+' terminal')
    if expected is not None: assert row['exit']==expected,(tag,(D/(tag+'.log')).read_text()[-2500:])
    return row['exit']

sources=[]
for name,digest in prior['fixture_SHA256'].items():
    if name in ['phase.sv','tb.sv']: continue
    b=(a.previous/'source'/name).read_bytes()
    assert sha(b)==digest,name
    result['source_SHA256'][name]=digest
    target=S/name
    target.write_text(patch(b.decode(),a.mutation)) if name=='arm7_ds.sv' else target.write_bytes(b)
    sources.append(target)
s=(a.previous/'source/tb.sv').read_text()
begin=s.index(' a7_mul_phase #('); end=s.index(' nds_arm7_port',begin)
s=s[:begin]+' assign io=raw_io;\n'+s[end:]
s=s.replace(' arm7_ds #(', ' arm7_ds_trial #(')
s=s.replace('.i_rdata(iq),.i_ok(io),.d_req', '.phase_trial(policy!=0),.i_rdata_in(iq),.i_ok_in(io),.d_req',1)
monitor='''
 integer phasefd=0,phase_errors=0,phase_prepares=0,phase_commits=0,phase_finishes=0;
 int finish_cycle=-1,prepare_cycle=-1;logic[31:0]observed_next;
 always @(posedge clk)if(!rst&&active)begin
  if(cpu.phase_f_finish)begin phase_finishes++;finish_cycle=cycle;end
  if(cpu.phase_prepare)begin
   phase_prepares++;prepare_cycle=cycle;observed_next=cpu.pc+12;
   if(!(cpu.phase_f_finish||cpu.phase_owner_live)||cpu.i_addr!=cpu.pc+8)phase_errors++;
  end
  if(cpu.phase_next_commit)begin
   phase_commits++;
   if(!iconsume||iredirect||!cpu.phase_prepared||cycle<=prepare_cycle||cpu.phase_prepared_address!=observed_next)phase_errors++;
  end
  if(cpu.phase_internal_start&&finish_cycle<0)phase_errors++;
  if(iconsume||iredirect)begin finish_cycle=-1;prepare_cycle=-1;end
  $fdisplay(phasefd,"%0d,%h,%h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%h,%0d,%0d",
   cycle,cpu.pc,ia,cpu.ph,raw_io,cpu.i_ok,cpu.phase_f_finish,cpu.phase_internal_start,
   cpu.phase_prepare,cpu.phase_next_commit,cpu.phase_f_done,cpu.phase_prepared,cpu.esub,
   cpu.phase_prepared_address,iconsume,iredirect);
 end
'''
s=s.replace(' initial begin\n  if(!$value',monitor+'\n initial begin\n  if(!$value',1)
s=s.replace('  statefd=$fopen', '  phasefd=$fopen({out,".phase"},"w");\n  $fdisplay(phasefd,"cycle,pc,ia,ph,raw_ok,effective_ok,F_finish,internal_start,prepare,next_commit,F_done,prepared,esub,next_address,consume,redirect");\n  statefd=$fopen')
s=s.replace('  $fclose(statefd);', '''  $display("PHASE_FUNCTION_PASS errors%0d prepares%0d commits%0d finishes%0d",phase_errors,phase_prepares,phase_commits,phase_finishes);
  if(policy!=0&&region!=0)begin
   assert(phase_prepares==loops*64&&phase_commits==loops*64&&phase_finishes==loops*64)else $fatal(1,"PHASE_COUNT");
  end
  assert(phase_errors==0)else $fatal(1,"PHASE_PROTOCOL_MUTATION_CAUGHT errors%0d",phase_errors);
  $fclose(phasefd);
  $fclose(statefd);''')
(S/'tb.sv').write_text(s); sources.append(S/'tb.sv')
result['fixture_SHA256']={f.name:sha(f.read_bytes()) for f in sources}; save()
if a.reuse_model:
    reused=json.loads((a.reuse_model/'results.json').read_text())
    assert reused['fixture_SHA256']==result['fixture_SHA256']
    model=a.reuse_model.resolve()/'obj/Vtb'
    assert sha(model.read_bytes())==reused['model_SHA256']
    result['reused_model']=dict(path=str(model),SHA256=reused['model_SHA256'])
else:
    call([a.verilator,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb','--Mdir',D/'obj',*sources],'build',180)
    model=D/'obj/Vtb'
result['model_SHA256']=sha(model.read_bytes());save()
symbols=prior['symbols']
template=next(x['cmd'] for x in prior['stages'] if x['tag']=='k1-c0-r1-p0-n4')
for case,(rs2,rs6) in enumerate([(127,127),(2147483647,2147483647),(127,2147483647)]):
    for region in ([1] if a.mutation!='none' else [0,1]):
        policies={}
        for policy in ([1] if a.mutation!='none' else [0,1]):
            values={}
            for n in ([4] if a.mutation!='none' else [4,16]):
                tag=f'c{case}-r{region}-p{policy}-n{n}'
                args={x.split('=',1)[0]:x.split('=',1)[1] for x in template[1:]}
                args.update({'+kernel':str(I/'1-kernel.hex'),'+wrapper':str(I/'1-wrapper.hex'),'+boot':str(I/'1-boot.hex'),
                             '+out':str(D/tag),'+case':str(case),'+rs':format(rs2,'x'),'+rs6':format(rs6,'x'),
                             '+region':str(region),'+policy':str(policy),'+loops':str(n),'+detail':'1'})
                rc=call([model,*[k+'='+v for k,v in args.items()]],tag,30,expected=None)
                log=(D/(tag+'.log')).read_text()
                assert 'PHASE_FUNCTION_PASS' in log,(tag,rc,log[-2200:])
                if a.mutation!='none':
                    if region==0: assert rc==0
                    else:
                        assert rc!=0 and 'PHASE_PROTOCOL_MUTATION_CAUGHT' in log
                        result.update(actual_fault_caught=True,fault_case=tag,state='actual protocol mutation caught after functional completion');save();status(result['state']);print(result['state']);raise SystemExit(0)
                else: assert rc==0,(tag,log[-2200:])
                values[str(n)]=int(re.search(r'MUL_PHASE_PASS.*elapsed(\d+)',log)[1])
            policies[str(policy)]=dict(elapsed_SYS=values,slope=(values['16']-values['4'])/1536)
        for n in [4,16]:
            for suffix in ['state','data']:
                b=[(D/f'c{case}-r{region}-p{policy}-n{n}.{suffix}').read_text().splitlines() for policy in [0,1]]
                assert [[x.split(',',1)[1] for x in lane] for lane in b][0]==[[x.split(',',1)[1] for x in lane] for lane in b][1]
                if region==0: assert b[0]==b[1], 'private route cycles changed'
                if region==1:
                    assert (a.previous/f'k1-c{case}-r1-p0-n{n}.{suffix}').read_bytes()==(D/f'c{case}-r1-p0-n{n}.{suffix}').read_bytes(),'disabled previous-cycle mismatch'
        target=next(x['slope'] for x in ds['summary'] if x['case_id']==case and x['region']==('MAIN' if region else 'private_WRAM'))
        row=dict(case_id=case,region=region,policies=policies,DS=target,enabled_matches=policies['1']['slope']==target)
        result['rows'].append(row);save();print('ROW',row,flush=True)
result['state']='MEASURED phase trial; DS equality independent, no production enable';save();status(result['state']);print(result['state'])
