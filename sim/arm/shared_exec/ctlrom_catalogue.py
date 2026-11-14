#!/usr/bin/env python3
"""Complete six-plane catalogue gate from exact source semantics."""
import os,pathlib,json,subprocess,re,fcntl,time,hashlib
os.setpriority(os.PRIO_PROCESS,0,10)
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-ctlrom';S=D/'source';Y=pathlib.Path.home()/'Git/openfpga-PlayStation/build/tools/oss-cad-suite/bin/yosys';H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
assert json.loads((D/'proof.json').read_text())['status']=='RECONSTRUCTION_MITER_PASS'
lock=open(pathlib.Path.home()/'.cache/nds-sim-build.lock','a');fcntl.flock(lock,fcntl.LOCK_EX)
files=[S/(n+'.sv')for n in ['arm_pkg','ctlrom_decode','ctlrom_descriptor']]
with(D/'descriptor-frontend.log').open('w')as log:p=subprocess.run([Y,'-Q','-T','-m','slang','-p','read_slang --allow-use-before-declare --top ctlrom_descriptor '+' '.join(map(str,files))+f'; proc; opt; opt_clean; scc; write_json {D}/descriptor-synthesis.json'],stdout=log,stderr=subprocess.STDOUT,timeout=60)
assert p.returncode==0,(D/'descriptor-frontend.log').read_text()[-1600:]
j=json.loads((D/'descriptor-synthesis.json').read_text());r={'sources':{p.name:H(p)for p in files},'descriptor_netlist_sha256':H(D/'descriptor-synthesis.json'),'planes':{},'M10K_cap':6,'row_cap':512}
for i in range(6):
 mod=j['modules']['ctlrom_descriptor'];cj=json.loads(json.dumps(j));cm=cj['modules']['ctlrom_descriptor'];bits=cm['ports']['p'+str(i)]['bits'];cm['ports']={k:v for k,v in cm['ports'].items()if v['direction']=='input'};cm['ports']['word']={'direction':'output','bits':bits};cm['netnames']['word']={'hide_name':0,'bits':bits,'attributes':{}}
 name='plane'+str(i);f=D/(name+'-projection.json');f.write_text(json.dumps(cj))
 with(D/(name+'-catalogue.log')).open('w')as log:q=subprocess.run([Y,'-Q','-T','-p',f'read_json {f}; hierarchy -top ctlrom_descriptor; opt_clean; sat -max 512 -show word'],stdout=log,stderr=subprocess.STDOUT,timeout=60)
 text=(D/(name+'-catalogue.log')).read_text();words=sorted({int(v,2)for v in re.findall(r'\\?word\s+\S+\s+\S+\s+([01]+)',text)});complete='no more models found'in text.lower();words=sorted(set(words)|{0});r['planes'][name]={'bits':len(bits),'words':words,'rows':len(words),'complete':complete,'exit':q.returncode,'ID_bits':(len(words)-1).bit_length()}
 (D/'catalogue.json').write_text(json.dumps(r,indent=2)+'\n');print(name,r['planes'][name]['rows'],len(bits),complete,flush=True)
 if not complete or len(words)>512:r['status']='CAPACITY_GATE_FAIL';(D/'catalogue.json').write_text(json.dumps(r,indent=2)+'\n');raise SystemExit(1)
 (D/(name+'.hex')).write_text('\n'.join(format(v,'x')for v in words+[0]*(512-len(words)))+'\n')
r['status']='SIX_PLANE_CAPACITY_PASS';(D/'catalogue.json').write_text(json.dumps(r,indent=2)+'\n')
