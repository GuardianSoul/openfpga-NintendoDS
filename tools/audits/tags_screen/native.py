"""Native vendor-branch shape elaboration, not Quartus inference/placement."""
from pathlib import Path
import ast,json,fcntl,re,hashlib
P=Path(__file__).with_name('screen.py');nodes=[]
for n in ast.parse(P.read_text()).body:
 if isinstance(n,ast.Expr)and isinstance(n.value,ast.Call)and isinstance(n.value.func,ast.Name)and n.value.func.id=='status':break
 nodes.append(n)
ns={'__file__':str(P.resolve())};exec(compile(ast.Module(body=nodes,type_ignores=[]),str(P),'exec'),ns);globals().update({k:v for k,v in ns.items()if k not in ['__name__','__file__']})
# Conditional hook is established by prefix capture plus actual cached-transaction
# dispatch. This is a composition lemma, not a full-controller reachability proof.
bh=header.replace('module writer(','module write_prefix(').replace('output logic[62:0]dt_ad','input[40:0]drow,irow,input[1:0]dirty,output bad,output logic[62:0]dt_ad')
# Take the fully named source-writer instance from the cost harness.
cp=Path(__file__).with_name('cost.py').read_text();a=cp.index('writer w(');b=cp.index(';',a)+1;inst=cp[a:b].replace('.ev_lane(ev_lane)', '.ev_lane(captured_ev)')
bridge=writer_module+bh+func+'''
wire[19:0]oldlane=vway?drow[39:20]:drow[19:0];
wire[20:0]captured_ev={oldlane[19],dirty[vway],oldlane[18:0]};
'''+inst+'''
wire legal_cached_transaction=(st!=S_TAGW||dp_kind==DK_LINE||(dp_kind==DK_FILL&&dp_a[31:22]==10'h008))&&(st!=S_ITAGW||iline||ip_a[31:24]==8'h02);
wire dp0=dt_we[0]&&dt_ad[20]&&dt_ad[18:9]!=10'h008;
wire dp1=dt_we[1]&&dt_ad[41]&&dt_ad[39:30]!=10'h008;
wire ip0=it_we[0]&&it_ad[19]&&it_ad[18:11]!=8'h02;
wire ip1=it_we[1]&&it_ad[39]&&it_ad[38:31]!=8'h02;
wire intent_bad=((|dt_we)&&(!busy_d||!(st==S_TAGW||(st==S_INV&&dline))))||((|it_we)&&(!busy_i||!(st==S_ITAGW||(st==S_INV&&!dline))));
assign bad=intent_bad||(vp_d(drow)&&vp_i(irow)&&legal_cached_transaction&&(dp0||dp1||ip0||ip1));
endmodule
'''
ram=__import__('subprocess').check_output(['git','show','af2b633e:rtl/arm/arm9_ram.sv'],cwd=R,text=True)
ports={'clock0','address_a','data_a','wren_a','byteena_a','q_a','address_b','data_b','wren_b','q_b'}
params=sorted(set(re.findall(r'\.([A-Za-z_]\w*)\s*\(',ram))-ports)
# Only an elaboration declaration; actual vendor semantics remain in arm9_ram
# and eventual Quartus. Defaults are immaterial because instances override them.
stub='(* blackbox *) module altsyncram #(\n'+',\n'.join('parameter '+n+'='+('32'if n in ['width_a','width_b']else'8'if n in ['widthad_a','widthad_b']else'1'if n.startswith('width_byteena')else'0')for n in params)+'''
)(input clock0,input[widthad_a-1:0]address_a,input[width_a-1:0]data_a,input wren_a,input[width_byteena_a-1:0]byteena_a,output[width_a-1:0]q_a,
input[widthad_b-1:0]address_b,input[width_b-1:0]data_b,input wren_b,output[width_b-1:0]q_b);endmodule
'''
(O/'native-declaration.sv').write_text(stub);(O/'source-arm9_ram.sv').write_text(ram)
r=json.loads((O/'result.json').read_text())
with(Path.home()/'.cache/nds-sim-build.lock').open('a')as lock:
 fcntl.flock(lock,fcntl.LOCK_EX);assert int(next(l.split()[1]for l in Path('/proc/meminfo').read_text().splitlines()if l.startswith('MemAvailable:')))>=12*1024*1024
 rc,log=run('actual-write-prefix',bridge,'prep -top write_prefix -flatten\nopt -full\nsat -verify -prove bad 0 -show-inputs -show-outputs\n');ok=rc==0 and'SUCCESS!'in log;r['cases'].append(dict(tag='actual-write-prefix',PASS=ok,rc=rc,scope='Conditional composition: actual write mux; cached-transaction/prefix hook plus liveoldtag invariant. Not monolithic reachability.'));print('actual-write-prefix',ok,flush=True);assert ok,log[-2200:]
 rc,log=run('native-elaboration',(O/'packed-native-intent.sv').read_text(),'read_verilog -sv -lib '+str(O/'native-declaration.sv')+'\nread_verilog -sv -D ALTERA_RESERVED_QIS '+str(O/'source-arm9_ram.sv')+'\nhierarchy -top packed_tag_intent\nflatten\nwrite_json '+str(O/'native-intent.json')+'\n');assert rc==0,log[-2200:]
 j=json.loads((O/'native-intent.json').read_text());cells=j['modules']['packed_tag_intent']['cells'];mem=[(n,c)for n,c in cells.items()if'alsyncram'in c['type']or'altsyncram'in c['type']];assert len(mem)==2,len(mem)
 def dec(v):
  return int(v,2)if isinstance(v,str)and set(v)<={'0','1'}else v
 summary=[{'name':n,'type':c['type'],'parameters':{k:dec(v)for k,v in c['parameters'].items()},'ports':c['connections']}for n,c in mem]
 for q in summary:
  p=q['parameters'];assert p['operation_mode']=='BIDIR_DUAL_PORT'and p['ram_block_type']=='M10K';assert p['width_a']==p['width_b']==32 and p['widthad_a']==p['widthad_b']==8 and p['numwords_a']==p['numwords_b']==256;assert q['ports']['wren_b']==['0'];assert p['read_during_write_mode_mixed_ports']=='DONT_CARE'
 r['native_intent']={'elaboration_PASS':True,'banks':summary,'nominal_requested_M10K':4,'measured_vendor_inference':False,'scope':'Currentarm9_ram nativebranch elaborated against declaration-only altsyncram. 2independent256x32TDP banks,1fullwordAwrite/Breadonly,unchangedclock/mixedportmode. Not Quartus validation.'};r['cases'].append(dict(tag='native-elaboration',PASS=True,rc=rc));print('native shape PASS:2x256x32TDP',flush=True)
(O/'result.json').write_text(json.dumps(r,indent=2)+'\n')
