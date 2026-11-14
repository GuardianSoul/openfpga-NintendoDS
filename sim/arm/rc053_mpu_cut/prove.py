from pathlib import Path
import subprocess,re,json,hashlib,os,datetime
R=Path(__file__).resolve().parents[3];os.chdir(R);os.setpriority(os.PRIO_PROCESS,0,10);O=R/'build/rc053-mpu-cut/proof';O.mkdir(parents=True,exist_ok=True)
p='rtl/arm/arm9_mem.sv';s=Path(p).read_text();old=subprocess.check_output(['git','show','334c58ee:'+p],text=True)
func=s[s.index('  function automatic logic [3:0] cut_of'):s.index('  logic [19:0] dtcm_base')]
inverse=s.replace(func,'').replace('logic [9:0]  mr_b [0:7];\n  logic [3:0]  mr_cut [0:7];','logic [9:0]  mr_b [0:7], mr_m [0:7];').replace('& mask_of_cut(mr_cut[n]))','& mr_m[n])').replace('mr_cut[w_crm[2:0]] <= cut_of(w_wdata[5:1]);','mr_m[w_crm[2:0]] <= c6_msk[9:0];')
assert inverse==old,'exact memory inverse'
for f in ['arm9_core','arm_cpu','arm7_ds','arm_pkg','arm_regfile','arm_mul','arm_thumb','arm_core','arm9_ram']:
 path='rtl/arm/'+f+'.sv';assert Path(path).read_bytes()==subprocess.check_output(['git','show','334c58ee:'+path]);assert Path(path).read_bytes()==subprocess.check_output(['git','show','286a7190:'+path])
assert old==subprocess.check_output(['git','show','286a7190:'+p],text=True)
mask=old[old.index('  function automatic logic [19:0] rmask_of'):];mask=mask[:mask.index('  endfunction')+len('  endfunction')]
def normalize(t):
 name=re.search(r'function automatic logic(?: \[.*?\])? (\w+)',t).group(1)
 return re.sub(r'return (.*?);',lambda m:name+' = '+m.group(1)+';',t)
mask=normalize(mask);cut=normalize(func[:func.index('  endfunction')+len('  endfunction')]);dec=func[func.index('  function automatic logic [9:0] mask_of_cut'):]
cut=cut.replace("4'(size - 5'd11)","(size - 5'd11)");dec=dec.replace("4'(i)",'i')
# One shared copy of unchanged valid/base/readback state: exact inverse binds its
# entire transition and read equations; only the mask representation is doubled.
model='''module miter(input clk,rst,cp_write,input[3:0] w_crn,input[3:0] w_crm,input[31:0] w_wdata,input[9:0] address,input[7:0] dcb,wbb,input found,output bad,output relation_bad);
FN
reg[7:0] valid;reg[9:0] base[0:7];reg[9:0] masks[0:7];reg[3:0] cuts[0:7];
wire[19:0] c6_msk=rmask_of(w_wdata[5:1]);
always @(posedge clk) begin
 if(rst) valid<=0;
 else if(cp_write && w_crn==6) begin
  valid[w_crm[2:0]]<=w_wdata[0] && (((w_wdata[31:22]^10'h008)&c6_msk[19:10])==0);
  base[w_crm[2:0]]<=w_wdata[21:12]&c6_msk[9:0];
  masks[w_crm[2:0]]<=c6_msk[9:0];
  cuts[w_crm[2:0]]<=cut_of(w_wdata[5:1]);
 end
end
reg[7:0] a,b;reg rb;reg ca,cb,ba,bb;
always @* begin
 rb=0;ca=0;cb=0;ba=0;bb=0;
 for(integer n=0;n<8;n=n+1)begin
  a[n]=valid[n]&&(((address^base[n])&masks[n])==0);
  b[n]=valid[n]&&(((address^base[n])&mask_of_cut(cuts[n]))==0);
  rb=rb||(valid[n]&&(masks[n]!=mask_of_cut(cuts[n])));
  if(a[n])begin ca=dcb[n];ba=found&&wbb[n];end
  if(b[n])begin cb=dcb[n];bb=found&&wbb[n];end
 end
end
assign bad=(a!=b)||(ca!=cb)||(ba!=bb);assign relation_bad=rb;
endmodule
'''
needle="size >= 5'd21";assert s.count(needle)==1;fault=s.replace(needle,"size >= 5'd20");(O/'actual-cut-fault-mem.sv').write_text(fault)
result=dict(parent='334c58ee',control_CPU_equal_286=True,exact_inverse=True,source_SHA256=hashlib.sha256(s.encode()).hexdigest(),readback_response_noninterference='entire memory file inverse; only mask declaration/write/match and two pure helper functions differ; cprb/base/valid/all response/state equations identical',cases=[])
for tag,c in [('equiv',cut),('saturation_fault',cut.replace(needle,"size >= 5'd20"))]:
 text=model.replace('FN',mask+'\n'+c+'\n'+dec);sv=O/(tag+'.sv');sv.write_text(text)
 ys=O/(tag+'.ys');ys.write_text('read_verilog -sv '+str(sv)+'\nprep -top miter -flatten\nmemory_map\nopt -full\n'+('sat -verify -tempinduct -seq 2 -maxsteps 6 -prove bad 0 -prove relation_bad 0'if tag=='equiv'else'sat -falsify -seq 3 -prove bad 0')+' -set-init valid 0 -show-inputs -show-outputs -dump_json '+str(O/(tag+'-witness.json'))+'\n')
 with (O/(tag+'.log')).open('w')as f:
  child=subprocess.Popen(['build/tools/oss-cad-suite/bin/yosys','-Q','-T','-s',str(ys)],stdout=f,stderr=subprocess.STDOUT)
  S=Path('/home/user/Git/NDS_Pocket/build/coordinator/units/CPUCompression.json');d=json.loads(S.read_text());d.update(phase='MPU_CUT_SMALL_SAT_'+tag,workers=[dict(host='Desktop',controller=os.getpid(),child=child.pid,NI=10,threads=1)]);t=S.with_suffix('.tmp');t.write_text(json.dumps(d));t.replace(S)
  try:rc=child.wait(timeout=45)
  except subprocess.TimeoutExpired:child.terminate();child.wait();raise
 log=(O/(tag+'.log')).read_text();ok=rc==0 and ('SUCCESS!'in log if tag=='equiv'else'model found: FAIL!'in log);print(tag,ok,flush=True);assert ok,log[-2000:]
 result['cases'].append(dict(tag=tag,PASS=ok,rc=rc))
result['PASS']=True;(O/'result.json').write_text(json.dumps(result,indent=2)+'\n')
