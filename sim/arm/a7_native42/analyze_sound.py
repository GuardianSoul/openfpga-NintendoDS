#!/usr/bin/env python3
"""Analyze the saved original ROI once; preserve raw DS phase and all samples."""
from pathlib import Path
import hashlib,json,sys
ROOT=Path(__file__).resolve().parents[3];S=ROOT/'build/a7-native42/sound';O=S/'result-c7684'
sys.path[:0]=[str(S/'helpers'),str(S/'reader')]
from sound_worker_trace import merge
from sound_v2_packet import report
from sound_setup_report import report as setup_report
from sound_setup_cpu_report import analyze as cpu_report
from sound_setup_qualify import qualify
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
parent=next(O.glob('sound-*.u_snd.u_sound_cycle.csv'));workers=list(O.glob('sound-*lane*.csv'));assert len(workers)==4
proof=merge(parent,workers,O/'derived.csv');r=report(O/'packet.bin',7684,O/'derived.csv',S/'inputs/DS',S/'inputs/Census',O/'analysis')
w=setup_report(O/'setup.csv');assert w['schema_version']==2 and w['writes']==121 and w['route_verified']==121
q=qualify(O);budget=cpu_report(O/'setup.csv',O/'analysis/report.json',O/'cpu-budget.json')
log=(O/'logs/full-core.log').read_text();assert 'A7_NATIVE39_ROUTE_OK'in log
assert 'models=0/0/0 video_errors=0 cart_errors=0'in log and 'vmcheck:'in log and '0 mismatches'in log
summary=dict(source=json.loads((S/'prepared/plan.json').read_text())['core_source'],profile=json.loads((S/'prepared/plan.json').read_text())['canonical_profile'],complete_packet=True,raw_DS_exact=r['raw16_exact_DS'],phase_alignment_used=r['phase_alignment_used'],setup_ticks=r['native_protocol']['first_enable_to_capture_arm_before'],poll_ticks=r['native_protocol']['elapsed_poll_ticks'],DS_units=[{k:u[k]for k in['samples','different','mean_abs','max_abs']}for u in r['comparisons']['DS']['units']],reader=dict(schema=w['schema_version'],writes=w['writes'],routes_verified=w['route_verified'],drain_scopes=w['drain_scopes']),observer_qualification=q['control'],CPU_data_occupancy=budget['between_gap_CPU_data_occupancy'],packet_SHA256=sha(O/'packet.bin'),setup_trace_SHA256=sha(O/'setup.csv'),scope='Original inherited checkpoint/timer seed preserved; no alignment or new Thumb price; direct DS PCM and whole protocol observations')
(S/'analysis.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2))
