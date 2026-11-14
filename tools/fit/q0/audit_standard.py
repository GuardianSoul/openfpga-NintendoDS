#!/usr/bin/env python3
"""Read installed Standard help files; never execute a Quartus process."""
from pathlib import Path
import hashlib,json,re
R=Path(__file__).resolve().parents[3];B=R/'build/q0-clock-gate/standard-help';B.mkdir(parents=True,exist_ok=True)
root=Path('build/tools/quartus-lite/25.1/quartus/common/tcl/internal/init')
required={'all_clocks':[], 'all_registers':[], 'get_clock_info':['-name','-period','-targets','-child_clocks'], 'get_node_info':['-name','-type'], 'get_register_info':['-name','-clock_edges'], 'get_fanins':['-clock','-through','-synch'], 'get_timing_paths':['-setup','-hold','-false_path','-from','-to','-npaths'], 'get_path_info':['-type','-slack','-clock_relationship','-setup_start_multicycle','-setup_end_multicycle','-hold_start_multicycle','-hold_end_multicycle','-from','-to','-from_clock','-to_clock'], 'report_exceptions':['-setup','-hold','-report_clock_groups','-from','-to','-from_clock','-to_clock','-npaths','-detail','-file'], 'report_sdc':['-file','-ignored'],'report_timing':['-setup','-hold','-to','-npaths','-nworst','-detail','-file'], 'get_registers':['-nowarn'], 'get_clocks':['-nowarn']}
H=lambda b:hashlib.sha256(b).hexdigest();bindings={};usage={}
for f in sorted(root.glob('*.hlp')):
 if 'advanced'in f.name:continue
 s=f.read_text(errors='replace')
 for cmd in required:
  if cmd in usage:continue
  if cmd=='get_node_info'and f.name!='sta.cmds.hlp':continue
  if cmd=='get_clocks'and f.name!='sdc.cmds.hlp':continue
  a=s.find('<'+cmd+'>');z=s.find('</'+cmd+'>',a)
  if a<0 or z<0:continue
  section=s[a:z+len(cmd)+3];line=next(l for l in section.splitlines()if l.startswith('Usage:'));usage[cmd]=line
  opts=set(re.findall(r'(?<!\w)-[a-z_]+',line));assert set(required[cmd])<=opts,(cmd,set(required[cmd])-opts)
  (B/(cmd+'.txt')).write_text(section);bindings[cmd]={'file':str(f),'file_SHA256':H(f.read_bytes()),'section_SHA256':H(section.encode()),'usage':line}
assert set(usage)==set(required),set(required)-set(usage)
for cmd,bad in [('get_clocks','-of_objects'),('get_registers','-clock'),('all_registers','-clock'),('get_fanins','-stop_at_clocks'),('report_exceptions','-valid')]:assert bad not in re.findall(r'(?<!\w)-[a-z_]+',usage[cmd])
for p in [Path(__file__).with_name('collect.tcl'),Path(__file__).with_name('standard_clock.tcl')]:
 code='\n'.join(l for l in p.read_text().splitlines()if not l.strip().startswith('#'))
 assert '-of_objects'not in code and'-stop_at_clocks'not in code and' -valid 'not in code
j={'status':'PASS_SHIPPED_STANDARD_HELP_OPTION_AUDIT_NOT_RUNTIME_OR_STA','bindings':bindings,'new_clock_lookup':'get_fanins -clock -through DEFINING_TARGET REG, get_clock_info -targets/-child_clocks; nearest defined generated clock; no clock-name/target-name conflation. Unknown/multiple unrelated clocks or multiple defining targets fail.', 'actual_failure':'Root2161/25.1std Error332000 get_clocks-of_objects stopped beforeplacement. No resource verdict. Rootownsproductionfix/retry; actualapprovedqueue parse remainsgate.'}
(B.parent/'standard-api.json').write_text(json.dumps(j,indent=2)+'\n');print(j['status'])
