#!/usr/bin/env python3
"""Decode only the bounded observer export, never a raw native capture."""
import collections,gzip,json,os,struct,time
from pathlib import Path
R=Path(__file__).resolve().parents[3];B=R/'build/publication70';H=B/'candidate-host';EV=struct.Struct('<Q6IQ');T=14919;U64=(1<<64)-1
def J(p):return json.loads(p.read_text())
def put(p,v):p.write_text(json.dumps(v,indent=2)+'\n')
def rgb(v):return [((v>>s)&63)*4+(((v>>s)&63)>>4)for s in [0,6,12]]
def rows():
 with gzip.open(B/'observer-events.bin.gz','rb')as f:
  assert struct.unpack('<4I',f.read(16))[:3]==(0x33504453,1,40)
  while data:=f.read(40*32768):yield from EV.iter_unpack(data)
def main():
 os.setpriority(os.PRIO_PROCESS,0,10);start=time.monotonic();assert J(B/'passive-native-equality.json')['all_existing_bus_analysis_and_streams_exact']
 schema=J(H/'staged/overlay/sim/pocket_ds/publication70/schema.json');fields={f['name']:f for f in schema['fields']};groups={int(k):v for k,v in schema['groups'].items()};plan=J(R/'docs/results/raster-publication70-boundary-20261102/plan.json')
 owner=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/Raster.json');ov=J(owner);ov.update(phase='PUBLICATION70_BOUNDED_OBSERVER_DECODE',worker=[dict(pid=os.getpid(),starttime=Path('/proc/self/stat').read_text().split()[21],NI=10,jobs=1,threads=1)],lease='D1 one NI10 bounded decode; native/fullpass reaped');q=owner.with_suffix('.tmp');q.write_text(json.dumps(ov,separators=(',',':'))+'\n');assert q.stat().st_size<=2048;q.replace(owner)
 selected={(w['raw'],w['row']):w for w in plan['windows']};state={};pending=None;tick=None;readproof={};written={};pre={};linecounts={};lineends={};timeline=[];samples=[];output=[];pixels=[];layerall=[];win=-1;prior=None;known=unknown=0;counts=collections.Counter();globalsummary=[]
 def finish(t):
  nonlocal prior
  if t is None or win<0 or not state:return
  row=plan['windows'][win]['row'];raw=plan['windows'][win]['raw'];s=state
  if 'l3d_line'not in s:return
  interesting=abs(s['l3d_line']-row)<=2 or abs(s['lc_y']-row)<=1 and s['est']==6
  signature=tuple(s[n]for n in ['rb_v','rb_p','rb_y0','rb_y1','est','lc_ok','lc_pend','lc_ab','lc_expired','fp_wait','fp_act','fp_line','fp_d','st_full','st_pres','ring_have','l3d_rear','lv_go','l3d_go'])
  if interesting and signature!=prior:
   timeline.append(dict(time=t,raw_window=raw,**{n:s[n]for n in ['video_frame','shot','l3d_line','need','r_go','fp_line','fp_act','fp_d','fp_hold','st_full','st_pres','wdone','wsafe','est','lc_ok','lc_pend','lc_cnt','lc_y','lc_x','lc_ab','lc_expired','cp_ok','rd_ok','dir','rb_we_px','cp_we','lc_we','rb_v','rb_p','rb_y0','rb_y1','ring_have','l3d_rear','lv_go','l3d_go']}));prior=signature
  if s.get('rb_we'):
   branch=s['rb_source'];source_line=[s['px_y'],s['cp_y'],s['lc_y'],s['rd_y']][branch]
   written[(t,s['rb_wa'])]=dict(time=t,address=s['rb_wa'],data=s['rb_wd'],source=['direct','staging_copy','late_line_copy','SDRAM'][branch],source_line=source_line,lc_x=s['lc_x'],lc_px=s['lc_px'],fp_line=s['fp_line'],fp_act=s['fp_act'])
  if s.get('st_we')and s['px_y']==row:pixels.append(dict(time=t,raw_window=raw,line=row,x=s['px_x'],color=s['px_color']))
  if not s.get('stall',1)and s.get('s3_v')and s.get('j_line')==row and s.get('c_kind')!=7:
   x=s['s3_x'];layerall.append(dict(time=t,raw_window=raw,engine=s['j_eng'],line=row,x=x,kind=s['c_kind'],bg=s['s3_bg'],opaque=s['s3_bgop'],window_mask=s['wmask']))
   if s['j_eng']==0 and s['c_kind']==6:
    witness=readproof.get(2);writer=None
    if witness:writer=written.get((witness['last_write_time'],witness['address']))or pre.get((2,witness['address'],witness['last_write_time']))
    expected=((s['xs_rd']>>16&63)<<20)|((s['xs_rd']>>8&63)<<14)|((s['xs_rd']&63)<<8)|((s['xs_rd']>>24)|64)
    assert expected==s['s3_bg'],('LAYER_READ_FORMAT',t,x)
    samples.append(dict(time=t,raw_window=raw,video_frame=s['video_frame'],shot=s['shot'],line=row,x=x,layer_RGBA32=s['xs_rd'],layer_color=s['s3_bg'],opaque=s['s3_bgop'],ring_q=s['ring_q'],rear_q=s['rear_q'],rear_selected=s['l3d_rear'],ring_have=s['ring_have'],xs_xpos=s['xs_xpos'],xs_in=s['xs_in'],current_scrolled_address=s['xs_l3d_raddr'],actual_registered_read=witness,last_writer=writer))
  if s.get('out_valid')and s.get('draw_line')==row:output.append(dict(time=t,raw_window=raw,video_frame=s['video_frame'],shot=s['shot'],line=row,engine=s['out_eng'],x=s['out_x'],RGB8=rgb(s['out_rgb']),RGB18=s['out_rgb']))
 for t,k,port,a,d,x,y,z in rows():
  k-=5;counts[k]+=1;val=a|(d<<32)|(x<<64)|(y<<96)|(z<<128);sub=port>>16;chunk=port&65535
  if tick!=t:finish(tick);tick=t;readproof={}
  if k==59:
   win=val&255
   if win==255:win=-1
   prior=None;continue
  if 60<=k<=68:
   g=groups[k];chunks=(g['bits']+191)//192
   if chunk==0:pending=[t,k,sub,val,1]
   else:
    assert pending and pending[:3]==[t,k,sub]and pending[4]==chunk
    pending[3]|=val<<(192*chunk);pending[4]+=1
   if pending[4]==chunks:
    for name in g['fields']:
     f=fields[name];state[name]=(pending[3]>>(f['offset']-g['offset']))&((1<<f['width'])-1)
    pending=None
  elif k==69:
   assert chunk==0
   if sub<3:
    addr=val&1023;valid=(val>>10)&1;data=(val>>11)&((1<<71)-1);source=(val>>82)&0xffffffff;wt=(val>>114)&U64
    if valid:pre[(sub,addr,wt)]=dict(time=wt,address=addr,data=data,source_context=source,entry_predecessor=True,source_line=None)
   else:
    mem=sub-10;addr=val&1023;valid=(val>>10)&1;expected=(val>>11)&0x7fffff;actual=(val>>34)&0x7fffff;rt=(val>>57)&U64;wt=(val>>121)&U64
    assert rt==t-T and(not valid or expected==actual and wt<rt),('REGISTERED_READ_PROVENANCE',t,mem,addr)
    known+=valid;unknown+=not valid;readproof[mem]=dict(address=addr,known=bool(valid),expected=expected,actual=actual,request_time=rt,last_write_time=wt)
  elif 75<=k<=78:
   line=val&255;index=(val>>8)&65535;count=(val>>24)&U64;linecounts.setdefault(line,{})[f'{k}:{sub}:{index}']=count
  elif k==79:
   line=val&255;lineends[line]=dict(line=line,start=(val>>8)&U64,end=(val>>72)&U64,cycles=(val>>136)&0xffffffff)
  elif 70<=k<=74:globalsummary.append(dict(time=t,kind=k,subtype=sub,payload=val))
 finish(tick);assert pending is None
 stages=[]
 for line,r in sorted(lineends.items()):
  c=linecounts[line];n=r['cycles'];assert(r['end']-r['start'])//T==n
  hist=lambda k,sub,size:[c.get(f'{k}:{sub}:{i}',0)for i in range(size)]
  sh,fh,ph,ch=hist(75,0,16),hist(76,0,16),hist(76,1,8),hist(78,0,8);assert all(sum(x)==n for x in [sh,fh,ph,ch]);flags=hist(77,0,20);blocked=hist(76,3,16);assert sum(blocked)==sum(hist(76,4,8))==sum(v for k,v in c.items()if k.startswith('76:5:'))==flags[0]
  stages.append(dict(**r,store_state=sh,front_state=fh,phase=ph,canonical_state=ch,flags=flags,PS_blocked_front_state=blocked,PS_blocked_phase=hist(76,4,8),PS_blocked_pipeline_mask={k.split(':')[-1]:v for k,v in c.items()if k.startswith('76:5:')},pipeline_masks={k.split(':')[-1]:v for k,v in c.items()if k.startswith('76:2:')}))
 assert [x['line']for x in stages]==list(range(125,133));assert next(x for x in stages if x['line']==131)['cycles']==8870
 targets=[]
 for w in plan['windows']:
  raw,row=w['raw'],w['row'];ss=[x for x in samples if x['raw_window']==raw];oo=[x for x in output if x['raw_window']==raw];pp=[x for x in pixels if x['raw_window']==raw];ts=[x for x in timeline if x['raw_window']==raw]
  targets.append(dict(raw=raw,reference=w['reference'],row=row,deadline=w['diagnostic_deadline'][0],layer_reads=len(ss),finalpass_pixels=len(pp),output_pixels=len(oo),latch_observations=[x for x in ts if x['lv_go']and x['l3d_line']==row],new_wrong_pixel_observations=[dict(**p,layer=[x for x in ss if x['x']==p['x']],output=[x for x in oo if x['x']==p['x']])for p in w['new_wrong_pixels']]))
 result=dict(status='BOUNDED_OBSERVER_DATA_DECODED_NOT_AUTOMATIC_CAUSE_ACCEPTANCE',known_RAM_reads=known,unknown_RAM_reads=unknown,stages=stages,targets=targets,event_counts=dict(counts),scope='Actual source inputs, same original times. Screenshot mapping, prior writer and stage causes require explicit assessment; no phase/seed/frame/sample shifts.',seconds=time.monotonic()-start)
 put(B/'decoded-boundary.json',result)
 with gzip.open(B/'decoded-detail.json.gz','wt')as f:json.dump(dict(timeline=timeline,layer_samples=samples,outputs=output,producer_pixels=pixels,all_layer_samples=layerall,global_summaries=globalsummary),f)
 print(json.dumps(dict(status=result['status'],stages=[dict(line=x['line'],cycles=x['cycles'],flags=x['flags'],blocked_phase=x['PS_blocked_phase'])for x in stages],targets=[{k:v for k,v in x.items()if k!='new_wrong_pixel_observations'}for x in targets],known=known,unknown=unknown,seconds=result['seconds'])),flush=True)
 ov=J(owner);ov.update(phase='PUBLICATION70_SOURCE_ASSESSMENT',worker=[],lease='D1 native/extraction/bounded decode reaped; source assessment');q=owner.with_suffix('.tmp');q.write_text(json.dumps(ov,separators=(',',':'))+'\n');assert q.stat().st_size<=2048;q.replace(owner)
if __name__=='__main__':main()
