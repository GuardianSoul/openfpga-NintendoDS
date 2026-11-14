#!/usr/bin/env python3
"""Rerun the bounded complete-controller experiment; no fit or promotion."""
import pathlib,subprocess,os,fcntl,shutil,json,hashlib
os.setpriority(os.PRIO_PROCESS,0,10) # absolute NI10; inherited nice can be negative
W=pathlib.Path(__file__).resolve().parents[3];O=W/'build/cpu232-service-ucode'
T=pathlib.Path.home()/'Git/openfpga-PlayStation/build/tools/oss-cad-suite/bin'
O.mkdir(parents=True,exist_ok=True)
lock=open(pathlib.Path.home()/'.cache/nds-sim-build.lock','a');fcntl.flock(lock,fcntl.LOCK_EX)
mi=dict(line.split(':',1) for line in pathlib.Path('/proc/meminfo').read_text().splitlines())
guard={'absolute_nice':os.getpriority(os.PRIO_PROCESS,0),'memory_available':int(mi['MemAvailable'].split()[0])*1024,'disk_free':shutil.disk_usage(W).free,'lock_held':True}
(O/'guard.json').write_text(json.dumps(guard,indent=2)+'\n')
assert guard['memory_available']>=12*(1<<30),guard
assert guard['disk_free']>=30*(1<<30),guard
assert guard['absolute_nice']==10

def command(argv,log,expected=0):
 with (O/log).open('w') as f:p=subprocess.run(argv,cwd=W,stdout=f,stderr=subprocess.STDOUT)
 assert (p.returncode==0) if expected==0 else (p.returncode!=0),(argv,p.returncode,log)
 return (O/log).read_text()
def build(src,name):
 command([str(T/'verilator'),'--binary','--timing','--build','-j','4','-Wno-fatal','--top-module','tb','--Mdir',str(O/('obj_'+name)),str(O/'reference.sv'),str(O/src),str(W/'rtl/arm/arm9_ram.sv'),str(O/'tb.sv')],name+'-build.log')
 return str(O/('obj_'+name)/'Vtb')
import resource
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
subprocess.run(['python3',str(W/'sim/arm/service_ucode/oracle.py')],cwd=W,check=True)
s=(O/'reference.sv').read_text().replace('reference_mem','candidate_mem').replace('ref_packed_update','dut_packed_update');(O/'identity.sv').write_text(s)
identity=build('identity.sv','identity');assert 'PASS cycles=' in command([identity],'identity-run.log')
mutant=build('mutant.sv','mutant');assert 'ORACLE bus cycle=' in command([mutant],'mutant-run.log',1)
# Generate only after the identity and real mutation gate.
subprocess.run(['python3',str(W/'sim/arm/service_ucode/generate.py')],cwd=W,check=True)
candidate=build('candidate.sv','candidate')
for name,args in [('candidate-run.log',[]),('candidate-stall11.log',['+seed=1532ac7f','+stall=11']),('candidate-stall14.log',['+seed=7a1532cb','+stall=14'])]:
 out=command([candidate]+args,name);assert 'PASS cycles=' in out and 'states=7fff' in out,name
s=(O/'candidate.sv').read_text();a="service_rom[7] = 10'h18d;";b="service_rom[7] = 10'h1ad;";assert s.count(a)==1;(O/'candidate-fault.sv').write_text(s.replace(a,b))
fault=build('candidate-fault.sv','fault');assert 'ORACLE d_wait cycle=' in command([fault],'fault-run.log',1)
command(['python3',str(W/'tools/ds/qlint.py'),str(W/'rtl/arm/study/arm9_mem_ucode.sv')],'qlint.log')
# Synthesis frontend and process/memory lowering only; no mapping/area/timing claim.
script='read_slang --allow-use-before-declare --top arm9_mem_ucode -G WAYS=2 -G BURST=1 -G SLOW=1 -G EVB=1 -G EARLYD=1 -G XD=2 -G XI=1 -G OPT=1711268835 rtl/arm/arm_pkg.sv rtl/arm/arm9_ram.sv rtl/arm/study/arm9_mem_ucode.sv; proc; opt_clean; stat; write_json '+str(O/'synthesis.json')
command([str(T/'yosys'),'-Q','-T','-m','slang','-p',script],'synthesis.log')
command([str(T/'yosys'),'-Q','-T','-p','read_json '+str(O/'synthesis.json')+'; scc'],'candidate-scc.log')
refscript=script.replace('--top arm9_mem_ucode','--top arm9_mem').replace('rtl/arm/study/arm9_mem_ucode.sv','rtl/arm/arm9_mem.sv').replace('; stat;', '; scc; stat;').replace(str(O/'synthesis.json'),str(O/'reference-synthesis.json'))
command([str(T/'yosys'),'-Q','-T','-m','slang','-p',refscript],'reference-synthesis.log')
assert 'Found 0 SCCs.' in (O/'candidate-scc.log').read_text()
assert 'Found 0 SCCs.' in (O/'reference-synthesis.log').read_text()
print('PASS identity,3candidatewindows,2actualmutants,15enabledstates,real3bankconcurrency,qlint,synthesisfrontend;no fit/area acceptance')
