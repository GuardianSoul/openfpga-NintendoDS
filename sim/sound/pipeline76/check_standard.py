"""Check the actual action-selection rewrite, not Quartus crash resolution."""
from pathlib import Path
import hashlib,json,os,re,resource,subprocess
os.setpriority(os.PRIO_PROCESS,0,10)
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
root=Path(__file__).resolve().parents[3]
out=root/'build/sound/pipeline76-standard';out.mkdir(parents=True,exist_ok=True)
tools=Path('build/tools/oss-cad-suite/bin')
before=subprocess.check_output(['git','show','b5b1a775:rtl/sound/sound_engine.svh'],cwd=root,text=True)
after=(root/'rtl/sound/sound_engine.svh').read_text()
old=re.search(r'wire \[2:0\] next_act=([^;]+);',before).group(1)
new=re.search(r'(wire \[2:0\] next_act;.*?)(?=        wire \[31:0\] selected_word)',after,re.S).group(1)
states=re.search(r'typedef enum logic \[4:0\] \{([^}]+)\}',before,re.S).group(1)
ita=[v.strip() for v in states.split(',')].index('S_ITA')
header='input logic [4:0] st,input logic [2:0] it_act,act,output wire [2:0] y'
bench='''module tb;
reg [4:0] st;reg [2:0] it_act,act;wire [2:0] a,b;integer checks=0;
old o(st,it_act,act,a);candidate n(st,it_act,act,b);
initial begin
for(integer s=0;s<32;s++)for(integer i=0;i<8;i++)for(integer c=0;c<8;c++)begin
 st=s;it_act=i;act=c;#1;
 if(a!==b)$fatal(1,"ACTION_SELECTION_MISMATCH state=%0d it=%0d act=%0d old=%b new=%b",s,i,c,a,b);
 checks++;
end
assert(checks==2048)else $fatal(1,"binary coverage");
st=5'bxxxxx;
for(integer i=0;i<8;i++)for(integer c=0;c<8;c++)begin
 it_act=i;act=c;#1;
 if(a!==b)$fatal(1,"ACTION_SELECTION_MISMATCH X-selection");
end
$display("ACTION_SELECTION_EQ_PASS checks=2048 valid_and_invalid_state_codes X_selection=64");$finish;
end endmodule
'''
history=[]
for name,body in [('equivalent',new),('wrong-action-bit',new.replace('it_act[0]','~it_act[0]'))]:
    assert name=='equivalent' or body!=new
    text=(f'module old({header});localparam [4:0] S_ITA=5\'d{ita};assign y={old};endmodule\n'
          f'module candidate({header});localparam [4:0] S_ITA=5\'d{ita};{body}assign y=next_act;endmodule\n'+bench)
    sv=out/(name+'.sv');sv.write_text(text)
    with(out/(name+'.compile.log')).open('w')as f:
        subprocess.run([tools/'iverilog','-g2012','-s','tb','-o',out/name,sv],stdout=f,stderr=subprocess.STDOUT,check=True)
    r=subprocess.run([tools/'vvp',out/name],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    (out/(name+'.run.log')).write_text(r.stdout)
    assert (r.returncode==0 and 'checks=2048' in r.stdout) if name=='equivalent' else (r.returncode!=0 and 'ACTION_SELECTION_MISMATCH' in r.stdout)
    history.append({'case':name,'exit':r.returncode,'output':r.stdout})
receipt={'status':'PASS actual extracted rewrite; actual wrong-action-bit caught','NI':os.getpriority(os.PRIO_PROCESS,0),'PID':os.getpid(),
         'before':'b5b1a775','before_sha256':hashlib.sha256(before.encode()).hexdigest(),'after_sha256':hashlib.sha256(after.encode()).hexdigest(),
         'results':history,'limits':'No local Quartus execution. Crash resolution remains unconfirmed until Root next queued synthesis.'}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt))
