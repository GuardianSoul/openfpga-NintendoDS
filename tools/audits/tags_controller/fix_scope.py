"""Exhaustive one-transition proof from the actual inherited/fixed FSM branch."""
from pathlib import Path
import re,subprocess,json,hashlib,os
R=Path(__file__).resolve().parents[3];os.chdir(R);os.setpriority(os.PRIO_PROCESS,0,10);O=R/'build/rc10-tags-controller';O.mkdir(parents=True,exist_ok=True)
old=subprocess.check_output(['git','show','af2b633e:rtl/arm/arm9_mem.sv'],text=True);new=(R/'rtl/arm/arm9_mem.sv').read_text()
def branch(s):
 a=s.index('        S_ITAGW: begin\n');b=s.index('        S_PFCHK: begin\n',a);return s[a:b].split(':',1)[1]
def tokens(s):return re.sub(r'\s+','',re.sub(r'//[^\n]*|/\*.*?\*/','',s,flags=re.S))
a=old.index('        S_ITAGW: begin\n');b=old.index('        S_PFCHK: begin\n',a);c=new.index('        S_ITAGW: begin\n');d=new.index('        S_PFCHK: begin\n',c)
assert old[:a]==new[:c] and old[b:]==new[d:],'change outside I-tag commit branch'
# Exact token identity of the common exit, wrapped in the continuation's else.
common_old=branch(old).split('end else ',1)[1].rsplit('end',1)[0]
common_new=branch(new).split('end else begin',1)[1].rsplit('end',2)[0]
assert tokens(common_old)==tokens(common_new),'noncontinuation statements changed'
fields={'st':5,'swa_i':4,'k':3,'iline':1,'dp_v':1,'cmo_done':1,'pf_run':1,'ip_v':1,'pf_a':27}
def body(s,prefix):
 s=branch(s)
 for n in fields:s=re.sub(r'\b'+n+r'(?=\s*<=)',prefix+n,s)
 return s.replace('<=','=')
decl='\n'.join(f'(* anyconst *) reg [{w-1}:0] {n};'for n,w in {**fields,'sw_more_i':1,'PF':1,'wbuf_v':1,'ev_v':1,'ip_a':32}.items())
regs='\n'.join(f'reg [{w-1}:0] {p}{n};'for p in ['o_','n_']for n,w in fields.items())
def block(s,p):return 'always @* begin\n'+''.join(p+n+'='+n+';\n'for n in fields)+body(s,p)+'\nend\n'
equal=' && '.join('o_'+n+'==n_'+n for n in fields)
src='module fix_scope;\nlocalparam S_IDLE=0,S_ITAG=9,S_PFCHK=15;\n'+decl+'\n'+regs+'\n'+block(old,'o_')+block(new,'n_')+'\nalways @* begin\nif(!(iline && sw_more_i))assert('+equal+''');
if(iline && sw_more_i) begin
 assert(n_st==S_ITAG && n_iline && n_swa_i==4'(swa_i+1) && n_k==0);
 assert(n_dp_v==dp_v && n_cmo_done==cmo_done && n_pf_run==pf_run && n_ip_v==ip_v && n_pf_a==pf_a);
end
end
endmodule
'''
(O/'fix_scope.sv').write_text(src)
cmd=['build/tools/oss-cad-suite/bin/yosys','-Q','-T','-p',f'read_verilog -formal -sv {O}/fix_scope.sv; prep -top fix_scope; flatten; chformal -lower; sat -verify -prove-asserts -show-inputs']
r=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(O/'fix_scope.log').write_text(r.stdout);assert r.returncode==0,r.stdout[-2400:]
(O/'fix_scope.json').write_text(json.dumps(dict(PASS=True,scope='Actual S_ITAGW source branch; exhaustive one-step equality outside continuation, continuation preserves ownership and advances alias without exit. Exact source identity outside branch and common-exit token identity.',source_SHA256=hashlib.sha256(new.encode()).hexdigest()),indent=2)+'\n');print('actual-source fix transition scope PASS')
