#!/usr/bin/env python3
"""Actual ring write-yield protocol/data regression plus wrong-resume RTL fault.

Existing raster/display/random-SDRAM actor, unchanged value oracle. RPRI0
compares complete port cycles against2f; RPRI1 changes only service ordering.
"""
import hashlib,json,os,re,resource,subprocess,time,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3];OUT=ROOT/'build/ring65/unit';TMP=OUT/'work';V='build/tools/oss-cad-suite/bin/verilator'
def status(**kw):
 st.update(kw,updated=time.time());p=OUT/'status.tmp';p.write_text(json.dumps(st,indent=2)+'\n');p.replace(OUT/'status.json')
def run(cmd,name,fault=False):
 t=time.monotonic()
 with(OUT/(name+'.log')).open('w')as f:
  p=subprocess.Popen(list(map(str,cmd)),cwd=ROOT,stdout=f,stderr=subprocess.STDOUT,preexec_fn=lambda:resource.setrlimit(resource.RLIMIT_CORE,(0,0)))
  status(phase=name,child_pid=p.pid,child_starttime=Path(f'/proc/{p.pid}/stat').read_text().split()[21],command=list(map(str,cmd)));rc=p.wait()
 status(child_pid=None,**{name:dict(rc=rc,seconds=time.monotonic()-t)})
 if fault:assert rc and 'RESUME_MUTANT_CAUGHT'in(OUT/(name+'.log')).read_text()
 else:assert rc==0,(name,rc)
def prepare():
 before=subprocess.check_output(['git','show','2f86d1e69b0fc477d179375315acdefc1b438a68:rtl/ds/nds_g3d_ring.sv'],cwd=ROOT).decode().replace('module nds_g3d_ring #(','module ring_before #(',1);(TMP/'before.sv').write_text(before)
 after=(ROOT/'rtl/ds/nds_g3d_ring.sv').read_text();bad=after.replace("if (w_resume) sr_a <= {wdone[1:0], blk, 3'd0};", "if (w_resume) sr_a <= {wdone[1:0], 5'd0, 3'd0};",1);assert bad!=after
 (TMP/'mutant.sv').write_text(bad)
 tb=(ROOT/'sim/ds/tb_g3d_ring.sv').read_text().replace('parameter int YLAG = 0, parameter bit LLR = 0','parameter int YLAG = 2, parameter bit LLR = 1, parameter bit RPRI=1')
 tb=tb.replace('    nds_g3d_ring #(.YLAG(YLAG), .LLR(LLR)) dut (.*);','    logic rg_hurry;\n    nds_g3d_ring #(.YLAG(YLAG), .LLR(LLR), .RPRI(RPRI)) dut (.*);')
 # Exact inactive-control cycle relation to the original, under the actor's
 # same offered producer/display/memory traffic. No model alignment.
 clean=re.sub(r'//[^\n]*','',after[:after.index('\n);')]);ports=re.findall(r'\b(input|output)\s+logic\s*(\[[^\]]+\])?\s*(\w+)',clean)
 pp=[f'.{n}({"old_"if d=="output"else""}{n})'for d,w,n in ports]
 decl='\n'.join('logic '+w+' old_'+n+';'for d,w,n in ports if d=='output')
 check='\n'.join('if('+n+' !== old_'+n+') $fatal(1,"RPRI0 port '+n+'");'for d,w,n in ports if d=='output')
 extra='''
 longint pauses=0,words_checked=0;int previous_word=-1;bit test_mutant;
 initial test_mutant=$test$plusargs("mutant");
 always @(posedge clk) if(!rst) begin
  if(dut.w_block_end && dut.RPRI && dut.blk!=31 && (dut.rd_ok || dut.cp_ok || (dut.rd_on && !dut.drop))) pauses++;
  if(rg_wreq && rg_wack) begin
   int yy,xx; yy=int'(rg_waddr[15:8]);xx=int'(rg_waddr[7:0]);
   if(rg_wdata[22:0] !== pix(frame,yy,xx) && rg_wdata[22:0] !== pix(frame-1,yy,xx)) begin
    if(test_mutant) $fatal(1,"RESUME_MUTANT_CAUGHT actual wrong resumed staging word y%0d x%0d value%h",yy,xx,rg_wdata);
    $fatal(1,"WRITE_DATA y%0d x%0d value%h",yy,xx,rg_wdata);
   end
   if(previous_word>=0 && (previous_word&7)!=7 && int'(rg_waddr)!=previous_word+1) $fatal(1,"INCOMPLETE_WRITE_BLOCK");
   previous_word=int'(rg_waddr);words_checked++;
  end
 end
 generate if(!RPRI) begin:g_zero
'''+decl+'\nring_before #(.YLAG(YLAG),.LLR(LLR),.RPRI(0)) u_before('+','.join(pp)+');\nalways @(negedge clk) if(!rst) begin\n'+check+'\nend\nend endgenerate\n'
 tb=tb.replace('    int seed = 1, frames = 30,',extra+'\n    int seed = 1, frames = 30,',1)
 # Strong per-generation logical scoreboard. The producer tag travels with
 # the test actor's existing pixel NBA; it never drives the ring itself.
 tb=tb.replace('    int seed = 1, frames = 30,','    int producer_generation=0;\n    int seed = 1, frames = 30,',1)
 tb=tb.replace("                px_valid <= 1; px_x <= 8'(x);", "                producer_generation <= f; px_valid <= 1; px_x <= 8'(x);",1)
 scoreboard="""
 logic [22:0] intended[longint]; int sent[longint];
 int slot_generation[4],slot_line[4],publication_generation[192];
 int previous_done=0,previous_safe=0;
 longint exact_completed=0,published_lines=0,safe_lines=0,score_words=0;
 always @(posedge clk) if(!rst) begin
  if(px_valid) begin
   longint key;
   key=(64'(producer_generation)<<16)|(64'(px_y)<<8)|64'(px_x);
   intended[key]=px_color;
   if(px_x==0) begin slot_generation[px_y[1:0]]=producer_generation;slot_line[px_y[1:0]]=int'(px_y);end
  end
  if(rg_wreq && rg_wack) begin
   int yy,xx,gg;longint key,linekey;
   yy=int'(rg_waddr[15:8]);xx=int'(rg_waddr[7:0]);gg=slot_generation[yy%4];
   key=(64'(gg)<<16)|(64'(yy)<<8)|64'(xx);linekey=(64'(gg)<<8)|64'(yy);
   if(!intended.exists(key) || slot_line[yy%4]!=yy || intended[key]!==rg_wdata[22:0]) begin
    if(test_mutant) $fatal(1,"RESUME_MUTANT_CAUGHT generation/bank/resume value y%0d x%0d gen%0d",yy,xx,gg);
    $fatal(1,"EXACT_SOURCE_WORD y%0d x%0d gen%0d",yy,xx,gg);
   end
   if(!sent.exists(linekey))sent[linekey]=0;
   if(sent[linekey]!=xx) $fatal(1,"EXACT_ONCE_ORDER y%0d x%0d count%0d gen%0d",yy,xx,sent[linekey],gg);
   sent[linekey]++;score_words++;
   if(xx==255)begin if(sent[linekey]!=256)$fatal(1,"INCOMPLETE_LINE");exact_completed++;end
  end
 end
 always @(negedge clk) if(!rst) begin
  if(dut.wdone!=previous_done && dut.wdone!=0) begin
   int yy,gg;longint key;yy=int'(dut.wdone)-1;gg=slot_generation[yy%4];key=(64'(gg)<<8)|64'(yy);
   if(!sent.exists(key) || sent[key]!=256)$fatal(1,"EARLY_LINE_PUBLICATION");
   publication_generation[yy]=gg;published_lines++;
  end
  if(dut.wsafe>previous_safe) for(int yy=previous_safe;yy<int'(dut.wsafe);yy++) begin
   int gg;gg=publication_generation[yy];
   for(int xx=0;xx<256;xx++) begin
    longint key;int address;key=(64'(gg)<<16)|(64'(yy)<<8)|64'(xx);address=int'(dut.BASEW)+(yy<<8)+xx;
    if(!mem.exists(address) || !intended.exists(key) || mem[address][22:0]!==intended[key])$fatal(1,"EARLY_SAFE_PUBLICATION y%0d x%0d gen%0d",yy,xx,gg);
   end
   safe_lines++;
  end
  previous_done=int'(dut.wdone);previous_safe=int'(dut.wsafe);
 end
"""
 tb=tb.replace('    // SDRAM (integration',scoreboard+'\n    // SDRAM (integration',1)
 tb=tb.replace('        $display("RING65 words=', '        $display("RING65_SCORE exact_lines=%0d published=%0d safe=%0d words=%0d",exact_completed,published_lines,safe_lines,score_words);\n        $display("RING65 words=',1)
 tb=tb.replace('        $display("PASS");','        $display("RING65 words=%0d pauses=%0d RPRI=%0d",words_checked,pauses,RPRI);\n        if(RPRI && pauses==0) $fatal(1,"NO_YIELD_COVERAGE");\n        $display("PASS");',1)
 tb=tb.replace('        $display("RING65 words=', '        $display("RING65_SCORE exact_lines=%0d published=%0d safe=%0d words=%0d",exact_completed,published_lines,safe_lines,score_words);\n        $display("RING65 words=',1)
 (TMP/'tb.sv').write_text(tb)
 status(inputs={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in [ROOT/'rtl/ds/nds_g3d_ring.sv',Path(__file__),ROOT/'sim/ds/tb_g3d_ring.sv']},generated={p.name:hashlib.sha256(p.read_bytes()).hexdigest()for p in TMP.glob('*.sv')})
if __name__=='__main__':
 os.setpriority(os.PRIO_PROCESS,0,10);OUT.mkdir(parents=True,exist_ok=True);TMP.mkdir(exist_ok=True);st=dict(controller_pid=os.getpid(),controller_starttime=Path('/proc/self/stat').read_text().split()[21],NI=os.nice(0),jobs=1,threads=1)
 try:
  if '--stress-only'in sys.argv:
   st.update(json.loads((OUT/'original-chain-status.json').read_text()))
   st.update(controller_pid=os.getpid(),controller_starttime=Path('/proc/self/stat').read_text().split()[21])
   for name,args in [('late-restart',['+slow=300','+heavy=10']),('drained-fence',['+wfix=512','+heavy=20'])]:
    run([TMP/'candidate/Vtb_g3d_ring','+frames=5','+seed=65',*args],name)
  else:
   prepare();run(['python3','tools/ds/qlint.py','rtl/ds/nds_g3d_ring.sv'],'qlint')
   for mode in ['candidate','inactive','mutant']:
    src=TMP/'mutant.sv'if mode=='mutant'else ROOT/'rtl/ds/nds_g3d_ring.sv';obj=TMP/mode
    run([V,'--binary','--timing','--build','-j','1','--threads','1','-Wno-fatal','--top-module','tb_g3d_ring','-GRPRI='+('0'if mode=='inactive'else'1'),'--Mdir',obj,ROOT/'rtl/gpu3d/gpu3d_ram.sv',src,TMP/'before.sv',TMP/'tb.sv'],mode+'-build')
    for seed in ([65]if '--strong-only'in sys.argv else[1,19,65]if mode=='candidate'else[65]):
     run([obj/'Vtb_g3d_ring','+frames=5','+seed='+str(seed),'+heavy=20','+wlag=150',*(['+mutant']if mode=='mutant'else[])],mode+'-'+str(seed),mode=='mutant')
  status(phase='PASS',child_pid=None)
 except BaseException as e:status(phase='FAIL',error=repr(e));raise
