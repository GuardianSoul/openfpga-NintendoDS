#!/usr/bin/env python3
"""Actual complete caches: hash0/hash1, fill/hold/scrub/generation and state."""
import argparse,hashlib,json,os,resource,re,subprocess,tarfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);a=p.parse_args()
os.setpriority(os.PRIO_PROCESS,0,10);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
print(f'worker_pid={os.getpid()} starttime={Path("/proc/self/stat").read_text().split()[21]} nice=10 jobs=1 threads=1',flush=True)
names=['gpu2d_ram','gpu2d_ram_be','gpu2d_mlab_od','gpu2d_mlab','gpu2d_mlab_be','gpu2d_m10k','gpu2d_cgen','gpu2d_cache']
pat=r'\b('+ '|'.join(names)+r')\b'
oldfiles=[]
for leaf in ['ram','cache']:
 s=subprocess.check_output(['git','show','23cae397:rtl/gpu2d/gpu2d_'+leaf+'.sv'],cwd=ROOT,text=True)
 s=re.sub(pat,lambda m:m[0]+'_before',s);f=out/f'before_{leaf}.sv';f.write_text(s);oldfiles.append(f)
(out/'driver.cpp').write_bytes((ROOT/'sim/gpu2d/olddata_mlab/cache.cpp').read_bytes())
top=['''module tb_od_cache(input logic clk,clear,idle,hold,fill_we,fill_last,input logic [17:0] a_blk,fill_blk,
input logic [1:0] a_word,fill_beat,input logic [63:0] fill_data,
output wire [17:0] cur_blk,output logic [31:0] wraps=0,held=0,fill_collisions=0,raw_collisions=0,scrub_writes=0);
import gpu2d_pkg::*;
wire [9:0] gen;wire [5:0] scrub,scrub_q;wire scrub_v;
gpu2d_cgen #(.SW(6)) cgen(.clk,.clear,.idle,.gen,.scrub,.scrub_q,.scrub_v);
''']
for i in range(2):
 for suffix,mod,tag in [('a','gpu2d_cache_before',0),('b','gpu2d_cache',1)]:
  top.append(f'wire [63:0] q_{suffix}{i};wire hit_{suffix}{i};wire [17:0] cur_{suffix}{i};wire [1:0] cw_{suffix}{i};')
  top.append(f'{mod} #(.IDXW(6),.TAG_MLAB({tag}),.HASH({i})) {suffix}{i}(.clk,.idle,.gen,.scrub,.scrub_q,.scrub_v,.hold,.a_blk,.a_word,.fill_we,.fill_blk,.fill_beat,.fill_last,.fill_data,.q(q_{suffix}{i}),.hit(hit_{suffix}{i}),.cur_blk(cur_{suffix}{i}),.cur_word(cw_{suffix}{i}));')
top.append('assign cur_blk=cur_a0;logic seen=0;always @(posedge clk)seen<=1;')
top.append('always @(negedge clk) if(seen) begin')
for i in range(2):
 top.append(f'if(q_a{i}!==q_b{i}||hit_a{i}!==hit_b{i}||cur_a{i}!==cur_b{i}||cw_a{i}!==cw_b{i})$fatal(1,"complete cache HASH{i} output mismatch");')
 top.append(f'''for(int k=0;k<64;k++) if(a{i}.g_tt.g_tr.u_tag.mem[k] !==
 ((b{i}.g_tt.g_tm.u_tag.pending_we&&b{i}.g_tt.g_tm.u_tag.pending_address==6'(k))?b{i}.g_tt.g_tm.u_tag.pending_data:b{i}.g_tt.g_tm.u_tag.mem[k]))
 $fatal(1,"complete cache HASH{i} logical tag state mismatch");''')
top.append('end')
top.append('''always @(posedge clk) begin
 wraps<=wraps+32'(clear&&gen==10'd1023);held<=held+32'(hold);
 fill_collisions<=fill_collisions+32'(fill_we&&a0.g_tt.tag_we&&a0.g_tt.tag_wa==a0.r_idx);
 raw_collisions<=raw_collisions+32'(b0.g_tt.g_tm.u_tag.pending_we&&b0.g_tt.g_tm.u_tag.pending_address==b0.r_idx);
 scrub_writes<=scrub_writes+32'(a0.g_tt.tag_we&&!fill_we);
end
endmodule
''')
(out/'wrapper.sv').write_text('\n'.join(top))
files=[ROOT/'rtl/gpu2d/gpu2d_pkg.sv',ROOT/'rtl/gpu2d/gpu2d_ram.sv',ROOT/'rtl/gpu2d/gpu2d_cache.sv']+oldfiles+[out/'wrapper.sv',out/'driver.cpp']
cmd=['build/tools/oss-cad-suite/bin/verilator','--cc','--exe','--build','-j','1','--threads','1','--assert','-Wno-fatal','--top-module','tb_od_cache','--Mdir',str(out/'obj'),'-CFLAGS','-std=c++20 -O1']+list(map(str,files))
with (out/'build.log').open('w') as log:r=subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
if r.returncode:raise SystemExit(f'BUILD_FAIL:{r.returncode}')
with (out/'run.log').open('w') as log:r=subprocess.run([str(out/'obj/Vtb_od_cache')],cwd=out,stdout=log,stderr=subprocess.STDOUT)
print((out/'run.log').read_text(),flush=True)
rec={'before':'23cae397','exit':r.returncode,'pid':os.getpid(),'starttime':Path('/proc/self/stat').read_text().split()[21],'nice':os.getpriority(os.PRIO_PROCESS,0),'jobs':1,'threads':1,'command':cmd,'source_hashes':{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files[:3]},'fixture_hashes':{f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in oldfiles+[out/'wrapper.sv',out/'driver.cpp']}}
(out/'receipt.json').write_text(json.dumps(rec,indent=2)+'\n')
with tarfile.open(out/'evidence.tar.gz','w:gz') as tar:
 for f in sorted(out.iterdir()):
  if f.is_file() and f.name!='evidence.tar.gz':tar.add(f,arcname=f.name)
raise SystemExit(r.returncode)
