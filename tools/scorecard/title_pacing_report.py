#!/usr/bin/env python3
import pathlib,csv,json,collections,statistics,hashlib,re,io
W=pathlib.Path(__file__).resolve().parents[2]; O=W/'build/title-pacing'
N=['cycles','retire9','retire7','bus9wait','main9wait','gx9wait','dma9busy','halt9','gx_io_busy','gx_req_wait','gx_io_writes','dx_accept','rasterbusy','fp_hold','final_pixels','capture_accept','capture_wait','geom_busy','geom_ds_full','geom_behind','storeheld','sortdone','entryexec','fetchwait','grantwait','fetch9wait','data9wait','gx_io_reads']
def stats(xs):
 return dict(n=len(xs),min=min(xs),median=statistics.median(xs),max=max(xs),sum=sum(xs)) if xs else dict(n=0)
def parse(dest):
 raw=(dest/'observer.csv.pacing.csv').read_text();raw=raw[:raw.rfind('\n')+1];rows=list(csv.reader(io.StringIO(raw)));events=collections.defaultdict(list);frames=collections.defaultdict(lambda:collections.Counter());bins=[]
 for r in rows:
  if not r or r[0].startswith('#'):continue
  events[r[0]].append(r)
  if r[0]=='BIN':
   vals=list(map(int,r[6:])); assert len(vals)==len(N)
   b={'cycle':int(r[1]),'frame':int(r[2]),'line':int(r[3]),'last_retire_pc9':r[4],'last_retire_pc7':r[5],**dict(zip(N,vals))};bins.append(b);frames[b['frame']].update({n:b[n] for n in N})
 loads=events['DLOAD'];saves=events['DSAVE'];hb=events['HB'];starts=events['DSTART']
 channels={}
 for k in range(8):
  hs=[r for r in hb if int(r[4])==k]; ls=[r for r in loads if int(r[4])==k];ss=[r for r in saves if int(r[4])==k and int(r[5])==2]
  channels[k]={'hblank_enabled_triggers':len(hs),'hblank_while_running':sum(int(r[5])!=0 for r in hs),'hblank_same_edge_finish':sum(any(s[1]==r[1] for s in ss) for r in hs),'loads':len(ls),'completed_runs':len(ss),'units_at_complete':dict(collections.Counter(r[7] for r in ss)),'run_start_to_finish_cycles':stats([int(r[1])-int(r[6]) for r in ss if int(r[6])>=0]),'routes_and_count':dict(collections.Counter(f'{r[5][:2]}xxxxxx->{r[6]},cnt={r[7]},remaining={r[8]},unit={r[9]},resume={r[10]}' for r in ls))}
 swaps=[r for r in events['GXFRAME'] if int(r[4])];sorts=[r for r in events['GXFRAME'] if int(r[5])];fg=[r for r in events['GXFRAME'] if int(r[6])];done=[r for r in events['GXFRAME'] if not int(r[8]) and not any(int(r[i]) for i in [4,5,6,7])]
 intervals=[]
 for i,s in enumerate(swaps):
  cyc=int(s[1]);prev=int(swaps[i-1][1]) if i else int(bins[0]['cycle'])-bins[0]['cycles'];bb=[b for b in bins if prev<b['cycle']<=cyc];total=collections.Counter()
  for b in bb:total.update({n:b[n] for n in N})
  intervals.append({'take_cycle':cyc,'frame':int(s[2]),'line':int(s[3]),'since_previous_or_window_start':cyc-prev,'whole_bin_counters_only':dict(total),'next_sort_done':next((int(r[1]) for r in sorts if int(r[1])>=cyc),None),'next_frame_go':next((int(r[1]) for r in fg if int(r[1])>=cyc),None)})
 return {'counter_names':N,'frames':dict(frames),'channels':channels,'swap_take_events':swaps,'sort_done_events':sorts,'frame_go_events':fg,'raster_done_edges':done,'swap_intervals':intervals,'raster_rows_per_displayframe':dict(collections.Counter(r[2] for r in events['RROW'])),'capture_rows_per_displayframe':dict(collections.Counter(r[2] for r in events['CAPROW'])),'bins':bins,'event_counts':{k:len(v) for k,v in events.items()},'limitations':['All counters overlap; never sum as exclusive CPU-cycle partition. Bins4096cycles can straddle stage edges.','Repeated HBlank while running is a coalesced opportunity, not proof of missed software-visible transfer.','SYS-only retire counts are valid for pinned CPU_FAST0; no fast-clock claim.','BIN counters group by ending video frame; up to4095cycles can be assigned across a frame boundary; not exact per-frame cycle partitions. Add1 to TP event labels for qualified observer join.','Imported fixed10frame window; no absolute DS steady-rate or coldboot inference.']}
if __name__=='__main__':
 d=parse(O/'title-on-observe');(O/'analysis.json').write_text(json.dumps(d,indent=2)+'\n');print(json.dumps({k:v for k,v in d.items() if k not in ['bins','frames','channels']},indent=2))
