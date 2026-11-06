#!/usr/bin/env python3
"""Validate supplemental epoch against the immutable ORIGINAL dispatch event."""
from pathlib import Path
import json

def check(directory):
 p=Path(directory);e=json.loads((p/'epoch.json').read_text());old=json.loads((p/'entry.json').read_text())
 assert e['command']==old['command']==7684 and e['stress']==old['stress']==0
 assert e['retired_pc']==old['arm7_retired_pc']==0x037f80a6,'supplemental metadata captured at wrong retirement boundary'
 assert e['prefetch_r15']==old['arm7_prefetch_r15'],'supplemental prefetch does not match original event'
 assert e['frame']==old['frame'] and e['line']==old['line'] and e['out_n']==old['out_n']==0
 assert e['source_unchanged_by_original_export'] is True
 c=e['clock'];last=e['last_mix'];prev=e['previous_mix'];event=e['spu_event']
 assert last['serial']==prev['serial']+1 and prev['serial']>0
 assert last['scheduled']-prev['scheduled']==last['interval']==event['mix_interval']
 assert last['param']*2==last['interval'] and event['scheduled']==last['scheduled']+last['interval']
 assert last['scheduled']<=last['SysTimestamp']<=c['SysTimestamp']<=c['ARM7Timestamp']
 assert event['enabled']==1
 st={x[0]:int(x[1],16)for l in (p/'state.txt').read_text().splitlines()if len(x:=l.split())==2 and x[0].startswith('timer')}
 for t in e['timers']:
  i=t['index'];assert t['Counter']>>10==st[f'timer{i}.counter'] and t['Cnt']==st[f'timer{i}.cnt'] and t['Reload']==st[f'timer{i}.reload']
 return dict(boundary='original same c7684 retirement',clock=c,last_mix=last,previous_mix=prev,spu_event=event,
             elapsed_CPU7_since_last_scheduled_mix=c['ARM7Timestamp']-last['scheduled'],
             elapsed_SYS_since_last_mix_callback=c['SysTimestamp']-last['SysTimestamp'],
             timer_lazy_elapsed=[(c['ARM9Timestamp']>>c['ARM9ClockShift'])-c['TimerTimestamp'][0],c['ARM7Timestamp']-c['TimerTimestamp'][1]],
             assumptions='Raw C19 epoch only; no guest advancement, normalization or DS timing inference')
