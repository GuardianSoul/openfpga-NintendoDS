#!/usr/bin/env python3
"""Input-only source proof, independent RAM/event replay and actual event fault."""
import argparse,hashlib,json,os,re,struct,subprocess,time
from pathlib import Path
from generate import generate
HERE=Path(__file__).resolve().parent;EV=struct.Struct('<Q6IQ');START=357000000000;T=14919
def replay(p,schema):
 groups={int(k):v for k,v in schema['groups'].items()};fields={f['name']:f for f in schema['fields']};seen={62:0,63:0,64:0};proof=0;line=False;count0=False
 def decode(k,payload):
  g=groups[k];return {n:(payload>>(fields[n]['offset']-g['offset']))&((1<<fields[n]['width'])-1)for n in g['fields']}
 for t,k,port,a,d,x,y,z in EV.iter_unpack(p.read_bytes()):
  k-=5;val=a|(d<<32)|(x<<64)|(y<<96)|(z<<128);sub=port>>16;chunk=port&65535;i=(t-START)//T
  if k in seen and chunk==0:
   v=decode(k,val);prefix={62:'rb',63:'st',64:'top'}[k]
   if v[prefix+'_we']:
    assert i<2048,'PUB70_EVENT_EXTRA_WRITE';expected=i%512 if k==62 else (3*i)%1024 if k==63 else i%1024
    assert v[prefix+'_wa']==expected,('PUB70_EVENT_ADDRESS_FAULT',k,t,v[prefix+'_wa'],expected)
    wd=v[prefix+'_wd']if k!=64 else v['top_lo'];seed,mul={62:(19,0x85ebca6b),63:(7,0x9e3779b9),64:(1,0x45d9f3b)}[k]
    assert wd==((i+seed)*mul)&0x7fffff;seen[k]+=1
  if k==69 and sub>=10:
   addr=val&1023;valid=(val>>10)&1;expected=(val>>11)&0x7fffff;actual=(val>>34)&0x7fffff;req=(val>>57)&((1<<64)-1);write=(val>>121)&((1<<64)-1)
   assert req==t-T and (not valid or expected==actual and write<req),('PUB70_OLD_DATA_PROVENANCE',t,sub,addr)
   proof+=valid
  if k==79:
   assert val&255==131 and (val>>136)&0xffffffff==50;line=True
  if k==70 and (val>>16)&65535==0:assert (val>>32)&((1<<64)-1)==4096;count0=True
 assert seen=={62:2048,63:2048,64:2048}and proof>8000 and line and count0,(seen,proof,line,count0)
 return dict(writes=seen,known_registered_reads=proof,line50cycles=True,global4096cycles=True)
def main():
 p=argparse.ArgumentParser();p.add_argument('destination',type=Path);args=p.parse_args();d=args.destination;os.setpriority(os.PRIO_PROCESS,0,10);generate(d);schema=json.loads((d/'schema.json').read_text());logs={}
 for mode,defines in [('normal',[]),('actual-event-fault',['-DPUB70_MUTATE_EVENT'])]:
  cmd=['g++','-std=c++17','-O2','-DPUB70_UNIT']+defines+[str(d/'observer.cpp'),str(d/'unit.cpp'),'-o',str(d/mode)]
  run=subprocess.run(cmd,capture_output=True,text=True);(d/(mode+'-build.log')).write_text(run.stdout+run.stderr);assert run.returncode==0
  cases=[('off',['off']),('on',[])]if mode=='normal'else[('fault',[])]
  for case,extra in cases:
   out=subprocess.check_output([str(d/mode),str(d/(case+'.bin'))]+extra,text=True);(d/(case+'.log')).write_text(out);logs[case]=out
 normal=replay(d/'on.bin',schema);caught=None
 try:replay(d/'fault.bin',schema)
 except AssertionError as e:caught=str(e)
 assert caught and 'PUB70_EVENT_ADDRESS_FAULT'in caught
 assert len({re.search(r'HASH ([0-9a-f]+)',s).group(1)for s in logs.values()})==1
 assert (d/'off.bin').stat().st_size==0
 cpp=(d/'observer.cpp').read_text();sv=(d/'observer.sv').read_text()
 assert not re.search(r'\b(vpi|svGetScope|svSetScope|const_cast|force|release)\b',cpp)
 assert not re.search(r'\b(output|inout|ref|force|release|assign|export)\b',sv.split('\n',1)[1])
 assert 'const uint32_t*v'in cpp and 'extern "C" void publication70_tick'in cpp
 result=dict(verdict='PASS_INPUT_ONLY_SOURCE_AND_FOCUSED_EVENT_QUALIFICATION',normal=normal,off_on_fault_parent_observable_hash='55d58b1db883f383',actual_observer_event_fault_caught=caught,mutation='First actual emitted RBuf write address bit, not a DUT mutation',source_contract=json.loads((d/'source-contract.json').read_text()),scope='Input-only/no-feedback source composition; C++ OLD_DATA fixture. Full native passivity/equality and hierarchy elaboration remain mandatory. No production RTL equivalence or DS acceptance claimed.')
 (d/'qualification.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
if __name__=='__main__':main()
