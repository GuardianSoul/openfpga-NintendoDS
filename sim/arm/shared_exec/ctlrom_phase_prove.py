#!/usr/bin/env python3
"""Actual-clock D/E ROM, raw token and late-input bounded symbolic gate."""
import pathlib,subprocess,json,os,fcntl,hashlib,time,resource,sys
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-ctlrom';S=D/'source';FAULT='--fault'in sys.argv;tag='phase-fault'if FAULT else'phase';STATUS=pathlib.Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json');H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
files=[S/(n+'.sv')for n in ['arm_pkg','ctlrom_decode_before','ctlrom_address','ctlrom_reconstruct','arm9_ctlrom_planes','arm9_ctlrom_packet','ctlrom_phase_miter']]
if FAULT:
 p=S/'phase_fault_miter.sv';p.write_bytes(files[-1].read_bytes().replace(b'parameter bit FAULT_TEMPLATE=0',b'parameter bit FAULT_TEMPLATE=1'));files[-1]=p
r={'status':'PHASE_PREPARING','fault':FAULT,'sources':{p.name:H(p)for p in files},'late_inputs_unconstrained':['hivec','hold_e','d_go','flush','rst_after_initial'],'owned_context_rule':'sameSYSupdatesasoriginal; next descriptor inputs arbitrary eachSYS, no raw IRQ/abort stability assumption','clock_steps':12}
def save():(D/(tag+'-proof.json')).write_text(json.dumps(r,indent=2)+'\n')
def status(p=None):
 s=json.loads(STATUS.read_text());s.update(phase='CTLROM_'+tag.upper()+'_SYMBOLIC',receipt=str(D/(tag+'-proof.json')),next_action='Actualbanks/twoports+rawtoken vsoriginalD/E, unconstrainedlatehivec/Mstall/dgo/flush/reset. Full sourcectxFFownership retained. Thenoriginal3cases+actualfault before80;no ownfit/game.',workers=[{'host':'Desktop','PID':os.getpid(),'NI':10,'peak_new_bytes':4294967296,'job':'ctlrom-phase'}]+([]if p is None else[{'host':'Desktop','PID':p.pid,'NI':os.getpriority(os.PRIO_PROCESS,p.pid),'job':tag}]),updated_at=time.time());v=json.dumps(s,separators=(',',':'));assert len(v)<2048;t=STATUS.with_suffix('.tmp');t.write_text(v+'\n');os.replace(t,STATUS)
status();lock=open(pathlib.Path.home()/'.cache/nds-sim-build.lock','a');fcntl.flock(lock,fcntl.LOCK_EX)
Y=pathlib.Path.home()/'Git/openfpga-PlayStation/build/tools/oss-cad-suite/bin/yosys';wave=' '.join(f'-set-at {i} clk {i%2}'for i in range(1,13));# start high then fall, first rise reset held
script='read_slang --allow-use-before-declare --top ctlrom_phase_miter '+' '.join(map(str,files))+f'; proc; opt; memory_dff; memory_map; opt; clk2fflogic; opt; write_json {D}/{tag}-synthesis.json; sat -seq 12 -set-init-zero {wave} -set-at 1 rst 1 -set-at 2 rst 1 -set-at 3 rst 1 -prove bad 0 -show-inputs -show bad -dump_json {D}/{tag}-counterexample.json'
with(D/(tag+'-miter.log')).open('w')as log:
 p=subprocess.Popen([Y,'-Q','-T','-m','slang','-p',script],stdout=log,stderr=subprocess.STDOUT);status(p)
 try:rc=p.wait(timeout=120)
 except subprocess.TimeoutExpired:p.terminate();rc=p.wait(timeout=10)
r['exit']=rc;r['script']=script;text=(D/(tag+'-miter.log')).read_text();ok=rc==0 and'no model found: SUCCESS'in text;r['status']=('PHASE_ACTUAL_WRONG_TEMPLATE_CAUGHT'if FAULT and rc==0 and'model found: FAIL'in text else'PHASE_PASS'if ok else'PHASE_COUNTEREXAMPLE_OR_ERROR');save();s=json.loads(STATUS.read_text());s.update(phase=r['status'],workers=[],updated_at=time.time());t=STATUS.with_suffix('.tmp');t.write_text(json.dumps(s,separators=(',',':'))+'\n');os.replace(t,STATUS);print(tag,r['status'])
