from pathlib import Path
import json,csv,collections,sys
W=Path(__file__).resolve().parents[3];B=Path(sys.argv[1]).resolve() if len(sys.argv)>1 else W/'build/sound-fabric39'
assert json.loads((B/'prefix-qualification.json').read_text())['status']=='PASS'
F=[{k:int(v)for k,v in r.items()}for r in csv.DictReader((B/'result/fabric.csv').open())];D={r['cycle']:r for r in F}
prior=B/'setup-partition-control.json';P=json.loads(prior.read_text())
STATE=['IDLE','GO','RAM','MAIN','FILL','WAIT','DONE','FR','Q7_HIT','QSN_HIT'];MASTER=['DMA','ARM9','ARM7','sound']

def label(r):
 if not r['a7_req']:return 'P7_request_not_presented_to_fabric'
 if r['sd_busy']:return 'sound_side_path_blocks_grant'
 if r['st']==0:
  if r['grant']&4:return 'ARM7_actual_grant'
  if r['grant']:return 'IDLE_grants_'+MASTER[(r['grant']&-r['grant']).bit_length()-1]
  return 'IDLE_no_grant'
 if r['mst']==2:
  return 'ARM7_own_'+STATE[r['st']]+('_IO'if r['tgt']==7 else'_other')
 return MASTER[r['mst']]+'_'+STATE[r['st']]

def stage(records):
 counts=collections.Counter();states=collections.Counter();items=[]
 for t in records:
  rows=[D[c]for c in range(t['first_port'],t['port_ACK']+1)]
  assert all(r['p7_f_req']and not r['p7_f_we']and r['p7_f_addr']==t['address']for r in rows)
  assert rows[-1]['p7_f_ack']and rows[-1]['a7_ack']and rows[-1]['io_ack']and not any(r['p7_f_ack']for r in rows[:-1])
  assert all(not r['a7_req']or r['a7_addr']==t['address']for r in rows)
  grants=[r['cycle']for r in rows if r['st']==0 and r['grant']&4]
  io=[r['cycle']for r in rows if r['io_req']and r['io_cpu']and r['io_addr']*4==t['address']&0xffffff]
  assert len(grants)==len(io)==1 and grants==io and t['port_ACK']==grants[0]+1, 'timer read must have one actual I/O grant and next-clock ACK'
  classes=collections.Counter(label(r)for r in rows[:-1]);counts.update(classes)
  states.update((MASTER[r['mst']]+'_'+STATE[r['st']])for r in rows[:-1])
  items.append(dict(CPU_request=t['begin'],CPU_done=t['end'],port_request=t['first_port'],port_ACK=t['port_ACK'],address=t['address'],grants=grants,IO_accept=io,classes=dict(classes),rows=rows))
 return dict(total=sum(counts.values()),classes=dict(counts),owner_state_counts=dict(states),grant_to_ACK_histogram=dict(collections.Counter(str(t['port_ACK']-g) for t in items for g in t['grants'])),requests=items)
result=dict(scope='Actualsource39 ONE passiveprearm observability run; strictoriginalprefixPASS',gaps=stage(P['timer_read_stages']),tail=stage(P['tail_timer_read_stages']))
assert result['gaps']['total']==536 and result['tail']['total']==62
assert result['gaps']['classes']=={'ARM7_actual_grant':45,'ARM9_GO':1,'ARM9_MAIN':8,'ARM9_FILL':316,'ARM9_DONE':19,'sound_FILL':125,'sound_DONE':8,'sound_MAIN':1,'sound_side_path_blocks_grant':13}
assert all(r['tgt']==1 for t in result['gaps']['requests'] for r in t['rows'][:-1] if r['mst']==1 and r['st']!=0 and not r['sd_busy'])
result['original_3012_DS2591_setup_gap_retained']=True
result['C19_shared_window_scope']='Accepted28b7fdc3 supplies earlier commonretirement prefix only; no SPU/mixer in window and no setup/DSphase inference.'
(B/'attribution.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:{x:v for x,v in y.items()if x!='requests'}for k,y in result.items()if isinstance(y,dict)},indent=2))
