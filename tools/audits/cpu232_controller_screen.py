#!/usr/bin/env python3
"""Source/netlist screen of complete retained CPU controllers; no fits or rebuilds."""
import pathlib,json,re,collections,hashlib,subprocess,os,resource,time
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
W=pathlib.Path(__file__).resolve().parents[2];D=W/'build/cpu232-controller-screen';D.mkdir(exist_ok=True);H=lambda b:hashlib.sha256(b).hexdigest()
P=W/'build/cpu232-retimed/retimed-synthesis.json';j=json.loads(P.read_text());m=j['modules']['retimed_top'];s=subprocess.check_output(['git','show','232c26ac:rtl/arm/arm9_core.sv'],cwd=W,text=True);st=s[s.index('  typedef struct packed {'):s.index('  } uop9_t;')];fields=[]
for line in st.splitlines():
 z=re.search(r'logic\s*(?:\[(\d+):(\d+)\])?\s*([^;]+);',line.split('//')[0])
 if z:
  width=int(z[1])-int(z[2])+1 if z[1] else 1
  fields.extend((n.strip(),width)for n in z[3].split(','))
q=set();ff_by_owner=collections.Counter();clkbits={n:m['ports'][n]['bits']for n in ['clk_sys','clk2']}
for n,c in m['cells'].items():
 if'dff'in c['type']:
  q.update(c['connections']['Q'])
  # Clocked states assigned by wire membership below; aliases must not be added.
rows={}
for prefix in ['retained.g_a9c.u_core9.','retained.g_a7ds.u_a7.','retained.u_mem9.']:
 union=set();records=[]
 for n,v in m['netnames'].items():
  if n.startswith(prefix)and'.'not in n[len(prefix):]and not n[len(prefix):].startswith('$'):
   live=set(v['bits'])&q;union|=live
   if live:records.append({'name':n[len(prefix):],'declared_bits':len(v['bits']),'live_FF_alias_bits':len(live)})
 rows[prefix]={'unique_FF_bits_in_direct_named_signals':len(union),'largest_named_aliases':sorted(records,key=lambda x:-x['live_FF_alias_bits'])}
end=301;eu=m['netnames']['retained.g_a9c.u_core9.eu']['bits'];u=m['netnames']['retained.g_a9c.u_core9.u']['bits'];payload={'valid','cond','pc','pcv','pcv_c','imm','link','wa','cp_op','msr_mask','exc_mode','lw'};fr=[];control=[]
for name,width in fields:
 lo=end-width;live=set(eu[lo:end])&q;fr.append({'name':name,'declared':width,'live':len(live),'offset':lo,'kind':'sideband'if name in payload else'template_candidate'})
 if name not in payload and live:control.extend(u[lo:end])
 end=lo
assert end==0
# Cut exact combinational output cone at state and RAM read boundaries. This is an
# unconstrained source superset, not a reachable-state or legal-instruction proof.
drivers={}
for n,c in m['cells'].items():
 for p,bs in c['connections'].items():
  if c['port_directions'].get(p)=='output':
   for b in bs:
    if isinstance(b,int):drivers[b]=n
selected={};leaves=set();seen=set()
def visit(bit):
 if not isinstance(bit,int)or bit in seen:return
 seen.add(bit)
 if bit in q:leaves.add(bit);return
 n=drivers.get(bit)
 if n is None:leaves.add(bit);return
 c=m['cells'][n]
 if 'mem'in c['type']or'dff'in c['type']or'latch'in c['type']:leaves.add(bit);return
 if n in selected:return
 selected[n]=c
 for p,bs in c['connections'].items():
  if c['port_directions'].get(p)=='input':
   for b in bs:visit(b)
for b in control:visit(b)
ports={'state_inputs':{'direction':'input','bits':sorted(leaves)},'control_word':{'direction':'output','bits':control}}
cone={'creator':'CPU232exact_combin_cone_projection','modules':{'control_projection':{'attributes':{},'ports':ports,'cells':selected,'netnames':{n:{'hide_name':0,'bits':p['bits'],'attributes':{}}for n,p in ports.items()}}}}
(D/'control-projection.json').write_text(json.dumps(cone))
def decode_block(text):
 a=text.index('  always_comb begin\n    logic [4:0] bank_ra');b=text.index('  // The instruction has more uops',a);return text[a:b]
retimed=(W/'rtl/arm/study/arm9_core_retimed.sv').read_text();assert decode_block(s)==decode_block(retimed)
r={'source':'232c26ac exact original controllers retained by774df','frontend_source_sha256':H(P.read_bytes()),'original_D_decode_block_sha256':H(decode_block(s).encode()),'D_decode_bytes_match_original':True,'source_field_inventory':fr,'controller_named_state':rows,'control_projection':{'width':len(control),'cut_inputs':len(leaves),'combinational_cells':len(selected),'not_reachability':True},'no_RTL_build_or_fit':True}
(D/'result.json').write_text(json.dumps(r,indent=2)+'\n');print(r['control_projection']);print('EU',sum(x['live']for x in fr),'sideband',sum(x['live']for x in fr if x['kind']=='sideband'),'template',sum(x['live']for x in fr if x['kind']=='template_candidate'))
Y=pathlib.Path.home()/'Git/openfpga-PlayStation/build/tools/oss-cad-suite/bin/yosys';t=time.time()
with(D/'control-template-superset.log').open('w')as log:
 p=subprocess.Popen([Y,'-Q','-T','-p',f'read_json {D}/control-projection.json; hierarchy -top control_projection; opt; sat -max 513 -show control_word'],stdout=log,stderr=subprocess.STDOUT)
 try:rc=p.wait(timeout=90)
 except subprocess.TimeoutExpired:p.terminate();rc=p.wait(timeout=10)
r['SAT']={'exit':rc,'seconds':time.time()-t,'PID':p.pid,'NI':os.getpriority(os.PRIO_PROCESS,0)};text=(D/'control-template-superset.log').read_text();patterns=re.findall(r'control_word\s+\S+\s+\S+\s+([01x]+)',text);r['SAT']['patterns_found']=len(set(patterns));r['SAT']['complete_no_more_models']='no more models found'in text.lower();(D/'result.json').write_text(json.dumps(r,indent=2)+'\n');print(r['SAT'])
# Exact per-plane catalogues: complete enumeration of the unconstrained cut.
groups={'execute':['a_zero','sh_type','amt_save','alu','qdbl','flags'],'memory':['mem','msize','msigned','norot','maddr','taddr','blk_pu','blk_u','st_save','st_temp'],'multiply':['mul_start','mul_kind','mul_signed','mul_xh','mul_yh','mulw','mulhi','macc','mlong','mflag','mq','mbub'],'flow':['last','wen','wsrc','wpc','rdr','rdx','pct','psr_spsr','msr','restore','exc','exc_f','set_thumb','clr_thumb','wfi','ldbh']}
import itertools
r['planes']={}
for group,names in groups.items():
 bits=[];layout=[]
 for f in fr:
  if f['name']in names and f['live']:
   layout.append({'field':f['name'],'plane_offset':len(bits),'width':f['declared'],'source_offset':f['offset']});bits.extend(u[f['offset']:f['offset']+f['declared']])
 cj=json.loads(json.dumps(cone));cm=cj['modules']['control_projection'];cm['ports']['control_word']['bits']=bits;cm['netnames']['control_word']['bits']=bits;proj=D/(group+'-projection.json');proj.write_text(json.dumps(cj))
 with(D/(group+'-SAT.log')).open('w')as log:z=subprocess.run([Y,'-Q','-T','-p',f'read_json {proj}; hierarchy -top control_projection; opt_clean; sat -max 513 -show control_word'],stdout=log,stderr=subprocess.STDOUT,timeout=30)
 text=(D/(group+'-SAT.log')).read_text();words=sorted({int(v,2)for v in re.findall(r'control_word\s+\S+\s+\S+\s+([01]+)',text)});complete='no more models found'in text.lower();assert z.returncode==0 and complete
 selected_bits=None
 for k in range((len(words)-1).bit_length(),len(bits)+1):
  for subset in itertools.combinations(range(len(bits)),k):
   mask=sum(1<<i for i in subset)
   if len({v&mask for v in words})==len(words):selected_bits=subset;break
  if selected_bits:break
 r['planes'][group]={'width':len(bits),'patterns':len(words),'complete_superset_enumeration':complete,'field_layout':layout,'catalogue_words':[format(v,'0'+str(len(bits))+'b')for v in words],'dense_ID_bits':(len(words)-1).bit_length(),'minimum_bit_projection':list(selected_bits),'bit_projection_depth':1<<len(selected_bits)}
 # Dense ROM contents are a source catalogue, not a free hardware ID encoder.
 depth=1<<(len(words)-1).bit_length();(D/(group+'-catalogue.hex')).write_text('\n'.join(format(v,'x')for v in words+[0]*(depth-len(words)))+'\n')
# Conservative complete-cell overlap is recorded, never read as bit-level area.
retained=set();retained_seen=set()
def retain_visit(b):
 if not isinstance(b,int)or b in retained_seen:return
 retained_seen.add(b)
 if b in q:return
 n=drivers.get(b)
 if n is None:return
 c=m['cells'][n]
 if'mem'in c['type']or'dff'in c['type']or'latch'in c['type']or n in retained:return
 retained.add(n)
 for port,bs in c['connections'].items():
  if c['port_directions'].get(port)=='input':
   for v in bs:retain_visit(v)
for f in fr:
 if f['kind']=='sideband'or not f['live']:
  for b in u[f['offset']:f['offset']+f['declared']]:retain_visit(b)
for n in ['more','nstep','nrl','nrl_r','mf']:
 for b in m['netnames'].get('retained.g_a9c.u_core9.'+n,{}).get('bits',[]):retain_visit(b)
r['decode_overlap']={'control_cone_cells':len(selected),'retained_dynamic_and_sequence_cells':len(retained),'overlap_cells':len(set(selected)&retained),'cell_names_nonadditive_not_ALMs':True}
r['native_disposition']={'774':'REJECTED2184','CPU_inclusive_before':4028.4,'CPU_inclusive_after':4169.5,'shared_integer_included':431.2,'not_additive':True,'no_reprice_requested':True}
r['selected_boundary']='wholeARM9Ddecodedpacket/routing construction and258bitEpacket -> factored route-template dualreadROM plus138bitrawEtoken; ARM7/F2/M/W/nativearm9_mem retained'
r['prototype_budget_not_fit_proof']={'control_planes_widths':[13,14,13,19],'routing_planes_max_widths':[17,17],'M10K_cap':6,'rows_per_plane_cap':512,'E_raw_token_bits':138,'prior_E_packet_live_FF':258,'ROM_read_logical_response_bits_max':186,'ROM_address_hold_bits_max':88,'preserve_other_SYS_FF_bits':2729,'not_proven':['routingcataloguewithin512','directsourceIDlogiccost','nativearea','ROMtoRFhalfSYStiming']}
(D/'result.json').write_text(json.dumps(r,indent=2)+'\n');print('PLANES',[(n,p['patterns'],p['width'])for n,p in r['planes'].items()]);print(r['decode_overlap'])
