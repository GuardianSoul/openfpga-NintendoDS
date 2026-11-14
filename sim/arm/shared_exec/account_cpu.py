#!/usr/bin/env python3
"""Account existing program bridge counters; do not add overlapping stall totals."""
import pathlib,json,re,hashlib
W=pathlib.Path(__file__).resolve().parents[3];D=W/'build/cpu232-shared-diagnostic';screen=json.loads((W/'build/cpu232-shared-cpu/result.json').read_text());r=json.loads((D/'result.json').read_text());out={'source':r['source'],'scope':'three original programs, observational counters only','counter_unit':'one halfSYS = one clk2 interval','partition_note':'F and D partitions separate; do not sum them or add overlapping waits/rewinds','barrier':'donor F->F2 and E3->WB require0.5SYS; held/registered bridge minimum1.5SYS plus replay/resume','cases':{}}
for name,row in r['cases'].items():
 assert row==screen['cases'][name],('observer changed outcome',name)
 text=(D/(name+'.log')).read_text();parts={}
 for line in text.splitlines():
  if line.startswith(('DIAG c=0 ','FCAT c=0 ','DCAT c=0 ','ILAT c=0 ','DLAT c=0 ')):parts[line.split()[0]]={k:int(v)for k,v in re.findall(r'(\w+)=(\d+)',line)}
 assert set(parts)=={'DIAG','FCAT','DCAT','ILAT','DLAT'}
 for group in ['FCAT','DCAT']:assert abs(sum(v for k,v in parts[group].items()if k!='c')-parts['DIAG']['slots'])<=1
 for label in ['ILAT','DLAT']:
  p=parts[label];p['mean_enqueue_ACK_SYS']=p['sum_halfSYS']/p['ack']/2;p['mean_ACK_consume_SYS']=p['afterACK_halfSYS']/p['consume']/2
 out['cases'][name]={'outcome_matches_screen':True,'counters':parts,'empty_decode_fraction':parts['DCAT']['empty']/parts['DIAG']['slots'],'hazard_fraction':parts['DCAT']['hazard']/parts['DIAG']['slots']}
for n in r['sources']:
 if n!='tb_arm.sv':assert r['sources'][n]==screen['sources'][n],('changed hardware',n)
out['all_hardware_hashes_match_screen']=True
(D/'accounting.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
