"""Original quiet DS30 prefix through LDM4, at its existing command-return point."""
from pathlib import Path
import importlib.util,json,re,sys
def validate(B,D):
 prepared=B/'prepared';sys.path.insert(0,str(prepared));spec=importlib.util.spec_from_file_location('d30_original_bodycheck',prepared/'check_observer.py');original=importlib.util.module_from_spec(spec);spec.loader.exec_module(original)
 m=json.loads((prepared/'hook-manifest.json').read_text());runtime=json.loads((B/'manifest.json').read_text());events=[json.loads(x)for x in (B/'ldm4-ds30.jsonl').read_text().splitlines()]
 beforeB=D/'before/runs/ds30';before=[json.loads(x)for x in (beforeB/'ldm4-ds30.jsonl').read_text().splitlines()]
 assert runtime['source']==m['source']and runtime['ROM_sha256']==m['ROM_SHA256']=='5163eb3cb0653b6278be3604e4abb827c85513d58175c67cb7e3987fea2e333e'
 assert events[0]==before[0]and events[-1]['event']=='ldm4_scoped_complete'and events[-1]['calls']==events[-1]['returns']==20
 calls=[x for x in events if x['event']=='command_call'];returns=[x for x in events if x['event']=='command_return']
 bc=[x for x in before if x['event']=='command_call'];br=[x for x in before if x['event']=='command_return']
 assert len(calls)==len(returns)==20 and [x['r0']for x in calls]==m['commands'][:20]and calls[-1]['r0']==18
 # Every complete existing event through the LDM invocation is unchanged,
 # including its absolute clock, full captured helper/CP15/IRQ/stack context.
 assert calls==bc[:20]and returns[:19]==br[:19],'changed pre-LDM context/prehistory'
 assert returns[0]['r0']==0x123456 and all(x['r0']!=0x3ffffff for x in returns)
 for key in ['pc','cpsr','sp','wramcnt','A7_WRAM','EXMEMCNT','POWCNT1','VRAMCNT','IME9','IE9','IME7','IE7','cp15']:
  assert returns[-1][key]==br[19][key],('LDM return context',key)
 ctx={x['stage']:x for x in events if x['event']=='checkpoint'};assert set(ctx)=={'ping','ldm4-endpoint'}
 for stage,c in ctx.items():
  bodies=[x for x in events if x['event']=='body'and x['stage']==stage]
  original.body_check((B/f'ldm4-ds30.{stage}.bodies.bin').read_bytes(),bodies,m,c['wramcnt'])
 assert ctx['ping']==next(x for x in before if x.get('event')=='checkpoint'and x.get('stage')=='ping')
 text=(B/'run.log').read_text();assert text.count('LDM4_DS30_SCOPED_ENDPOINT_OK bodies50 calls20 returns20')==1
 assert text.count('Verilog $finish')==1 and not re.search('DS30_OBSERVER_ERROR|DS30_OBSERVER_INCOMPLETE|TIMEOUT|%Error|%Fatal|Assertion failed|^FAIL$',text,re.M)
 assert re.search(r'^video: [1-9]\d* frames, 0 errors;.*underruns 0$',text,re.M)
 assert re.search(r'^models: sdram errors 0, cram errors 0/0; cart words [1-9]\d*, 0 on clk_bus edges$',text,re.M)
 assert re.search(r'^vmcheck: .*0 mismatches$',text,re.M)
 baseline=json.loads((beforeB/'checked.json').read_text())['guards']['rows'];rows=[]
 for i,event in enumerate(returns[1:]):
  row=dict(baseline[i]);row['arm7_cycles_per_op_x100']=str(event['r0']);row['core_over_DS']=event['r0']/row['DS_x100'];rows.append(row)
 assert rows[-1]['kernel']=='ldm4_main'and rows[-1]['arg']=='0'and rows[-1]['DS_x100']==1504
 return {'status':'SCOPED original LDM4/context/body/physical guards PASS; full31 enabled not claimed','rows':rows,'body_snapshots':50,'command_pairs':20,'prehistory_exact_to_LDM_call':True,'return_context_exact_except_timing_result_and_postmeasurement_ARM7_cursor':True,'omitted_later_rows':12,'scope':'Unchanged original guest and all warmups/short/long/5reps. Stop only after existing call18 returns. Original DS row1504 and before fullCSV<->actualreturn proof retained; no new oracle/offset/PC alignment. No full31 enabled acceptance.'}
