#!/usr/bin/env python3
"""Selected capture pixels from the bounded observer export, never native raw."""
import gzip,json,os,struct
from pathlib import Path
R=Path(__file__).resolve().parents[3];B=R/'build/publication70'
def main():
 os.setpriority(os.PRIO_PROCESS,0,10);s=json.loads((B/'candidate-host/staged/overlay/sim/pocket_ds/publication70/schema.json').read_text());g=s['groups']['68'];fields={f['name']:f for f in s['fields']};out=[]
 with gzip.open(B/'observer-events.bin.gz','rb')as f:
  f.read(16)
  while data:=f.read(40*65536):
   for t,k,p,a,d,x,y,z in struct.iter_unpack('<Q6IQ',data):
    if k!=73:continue
    value=a|(d<<32)|(x<<64)|(y<<96)|(z<<128);v={n:(value>>(fields[n]['offset']-g['offset']))&((1<<fields[n]['width'])-1)for n in g['fields']}
    if v['cap_we']and v['cap_ready']and v['draw_line']==134 and v['out_x']in range(145,157):out.append(dict(time=t,**v))
 (B/'capture-window-pixels.json').write_text(json.dumps(out,indent=2)+'\n');print('BOUNDED_CAPTURE_PIXELS',len(out))
if __name__=='__main__':main()
