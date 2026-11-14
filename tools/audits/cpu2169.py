"""Read retained failed-fit reports; no synthesis, simulation or mutation."""
from pathlib import Path
import json,hashlib,re,subprocess
R=Path(__file__).resolve().parents[2];O=R/'build/rc9-cpu2169-audit';O.mkdir(parents=True,exist_ok=True)
P=Path('/home/user/Git/NDS_Pocket/build/coordinator')
result={'sources':{'2159':'22dfd4dd15df18a5afd44ace674d6327d2f7bcf0','2169':'66372894946b725921a388a83a6ba2939beb3b56'},'report_hashes':{},'entities':{},'scope':'Failed-placement entity estimates: parentheses=own, outside=inclusive. Needed=A-B+C. No successful placement/STA or isolated change pricing.'}
def pair(v):
 m=re.fullmatch(r'([\d.]+)\s*\(([\d.]+)\)',v)
 return {'inclusive':float(m[1]),'own':float(m[2])}if m else{'inclusive':float(v),'own':None}
for tag in ['2159','2169']:
 result['entities'][tag]={}
 for kind in ['fit','map']:
  p=P/('fit'+tag)/('apf_top.'+kind+'.rpt');result['report_hashes'][str(p)]=hashlib.sha256(p.read_bytes()).hexdigest()
  for line in p.read_text(errors='replace').splitlines():
   a=[x.strip()for x in line.split(';')[1:-1]]
   if len(a)!=(16 if kind=='fit'else 10):continue
   entity=a[14 if kind=='fit'else 8];hier=a[13 if kind=='fit'else 7]
   if entity not in ['arm_cpu','arm9_core','arm9_mem','arm7_ds','arm_thumb']or'arm_cpu:g_one.u_cpu'not in hier:continue
   key=hier.split('|arm_cpu:g_one.u_cpu')[-1]or'CPU_wrapper';entry=result['entities'][tag].setdefault(key,{'entity':entity});entry[kind]={'raw':line}
   fields=({'needed_ALMs':1,'A_used_ALMs':2,'B_recoverable_ALMs':3,'C_unavailable_ALMs':4,'memory_ALMs':5,'ALUTs':6,'FFs':7,'block_bits':9,'DSP':10}if kind=='fit'else{'ALUTs':1,'FFs':2,'block_bits':3,'DSP':4})
   for field,idx in fields.items():entry[kind][field]=pair(a[idx])
result['delta_2169_minus_2159']={}
for key,old in result['entities']['2159'].items():
 if key not in result['entities']['2169']:continue
 new=result['entities']['2169'][key];result['delta_2169_minus_2159'][key]={kind:{field:{level:round(val[level]-old[kind][field][level],3)if val[level]is not None else None for level in ['own','inclusive']}for field,val in new[kind].items()if field!='raw'}for kind in ['fit','map']}
result['source_hashes']={f:hashlib.sha256(subprocess.check_output(['git','show','66372894:'+f],cwd=R)).hexdigest()for f in ['rtl/arm/arm9_core.sv','rtl/arm/arm_core.sv','rtl/arm/arm7_ds.sv','rtl/arm/arm9_mem.sv']}
(O/'entity-comparison.json').write_text(json.dumps(result,indent=2)+'\n')
for key in ['CPU_wrapper','|arm9_core:g_a9c.u_core9','|arm9_mem:u_mem9','|arm7_ds:g_a7ds.u_a7']:
 print(key,result['entities']['2169'][key]['fit']['needed_ALMs'],result['delta_2169_minus_2159'][key]['fit']['needed_ALMs'])
