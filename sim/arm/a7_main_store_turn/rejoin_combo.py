#!/usr/bin/env python3
"""Real MAIN-code IRQ plus posted-store/rejoin composition, four lanes."""
from pathlib import Path
import argparse, importlib.util, json, re, shutil, struct, subprocess, tarfile

ROOT=Path(__file__).resolve().parents[3]
parser=argparse.ArgumentParser();parser.add_argument('--turn',action='store_true');args=parser.parse_args();BASE='1711e153'if args.turn else'dbbff07b'
spec=importlib.util.spec_from_file_location('worker',ROOT/'sim/arm/a7_main_store_turn/run.py');w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
w.OUT=ROOT/('build/a7-if-turn-combo'if args.turn else'build/a7-if-rejoin-combo');d=w.OUT;d.mkdir(exist_ok=True)
with tarfile.open(ROOT/'docs/results/arm7-data-ack-20261101/proof.tar.gz')as t:
 physical=t.extractfile('cpu36/tb.sv').read().decode().split('module cpu_before ')[0]
physical=physical.replace('module physical_before ','module physical_transport ').replace('old_nds_psram #','nds_psram #')
physical=physical.replace('input logic a7_req,a7_we,a7_n4,a7_ifseq,','input logic[3:0]a7_be,input logic a7_req,a7_we,a7_n4,a7_ifseq,').replace(".a7_be(4'hf)",'.a7_be(a7_be)')
(d/'physical.sv').write_text(physical)
rels=['rtl/arm/arm_pkg.sv','rtl/arm/arm_thumb.sv','rtl/arm/arm7_ds.sv','rtl/ds/nds_arm7_port.sv','rtl/ds/nds_fabric.sv','rtl/ds/nds_mr_arb.sv','rtl/ds/nds_lcache.sv','rtl/ds/nds_ram.sv','rtl/gpu2d/gpu2d_ram.sv','rtl/gpu3d/gpu3d_ram.sv','rtl/mem/psx_pq_psram.sv','rtl/pocket/nds_psram.sv','sim/phase1/cram_model.sv','sim/phase1/sim_prims.sv']
for rel in rels:
 raw=(ROOT/rel).read_bytes()
 if rel!='rtl/ds/nds_arm7_port.sv':assert raw==subprocess.check_output(['git','show',BASE+':'+rel])
 (d/Path(rel).name).write_bytes(raw)
old=subprocess.check_output(['git','show',BASE+':rtl/ds/nds_arm7_port.sv']);(d/'old_nds_arm7_port.sv').write_bytes(old.replace(b'module nds_arm7_port #',b'module old_nds_arm7_port #',1))
tb=(ROOT/'sim/arm/a7_main_store_turn/tb_cpu.sv').read_text()
tb=tb.replace(".reset_pc(32'h03808000)",".reset_pc(32'h02080008)")
tb=tb.replace('.MAIN_STORE_TURN(MODE==2)', '.MAIN_IF_REJOIN(MODE==3),.MAIN_STORE_TURN(MODE>=2)')
tb=tb.replace('for(genvar M=0;M<3;M++)','for(genvar M=0;M<4;M++)').replace('wire[2:0]done','wire[3:0]done')
tb=tb.replace('g[2].lane.complete);','g[2].lane.complete&&g[3].lane.complete);')
tb=tb.replace(' integer statefd,datafd,edgefd,memfd;', ' integer statefd,datafd,edgefd,memfd,fcompfd;') if ' integer statefd' in tb else tb.replace('integer statefd,datafd,edgefd,memfd;', 'integer statefd,datafd,edgefd,memfd,fcompfd;')
tb=tb.replace('int cycle=0,nret=0,data_count=0,write_count=0,turns=0;', 'int cycle=0,nret=0,data_count=0,write_count=0,turns=0,adopts=0;')
needle=' always @(posedge clk)begin\n  cycle++;'
insert=''' generate if(MODE>0)begin:actual_activity
 always @(posedge clk)if(!rst)begin
 if(after_port.port7.rejoin_now)adopts++;
 if(after_port.port7.main_store_turn)turns++;
 end
 end endgenerate
 always @(posedge clk)if(!rst&&run&&(iconsume||(cpu.st==cpu.S_PIPE&&cpu.ph&&!cpu.if_wait&&!cpu.e_busy&&cpu.brt&&cpu.f_rq&&io)))
 $fdisplay(fcompfd,"%h,%b,%h,%b",ia,iseq,iq,!iconsume);
'''
assert tb.count(needle)==1;tb=tb.replace(needle,insert+needle)
needle='  $readmemh(image,wram);';assert tb.count(needle)==1
tb=tb.replace(needle,needle+'''
  fcompfd=$fopen($sformatf("%s-m%0d.fcomp",prefix,MODE),"w");
  for(int j=0;j<4096;j++)begin
   transport.chips.m0.mem[32'h80000/4+j]=wram[j][15:0];
   transport.chips.m1.mem[32'h80000/4+j]=wram[j][31:16];
  end''')
tb=tb.replace('  complete=1;', '  $fclose(fcompfd);$display("COMBO_ACTIVITY mode%0d rejoin%0d storeturn%0d",MODE,adopts,turns);\n  complete=1;')
if args.turn:
 tb=tb.replace('old_nds_arm7_port #(', 'old_nds_arm7_port #(.MAIN_IF_REJOIN(1),.MAIN_STORE_TURN(1),')
 tb=tb.replace('.MAIN_IF_REJOIN(MODE==3),.MAIN_STORE_TURN(MODE>=2)', '.MAIN_IF_TURN(MODE==2),.MAIN_IF_REJOIN(1),.MAIN_STORE_TURN(1)')
 tb=tb.replace('for(genvar M=0;M<4;M++)','for(genvar M=0;M<3;M++)').replace('wire[3:0]done','wire[2:0]done').replace('&&g[3].lane.complete','')
 tb=tb.replace('turns=0,adopts=0;', 'turns=0,adopts=0,nturns=0,stails=0;')
 tb=tb.replace('if(after_port.port7.main_store_turn)turns++;', '''if(after_port.port7.main_store_turn)turns++;
 if(after_port.port7.flow_n_turn&&!after_port.port7.wb_v&&!after_port.port7.d_blk&&!(dr&&after_port.port7.dreg==0))nturns++;
 if(after_port.port7.flow_s_tail&&after_port.port7.flow_prefetch)stails++;''')
 tb=tb.replace('  complete=1;', '  $display("TURN_ACTIVITY mode%0d N%0d S%0d",MODE,nturns,stails);\n  complete=1;')
(d/'tb_cpu.sv').write_text(tb)
asm=(ROOT/'sim/arm/a7_main_store_turn/main.s').read_text().replace('_start:\n',' .space 8\n_start:\n .rept 4\n b .+16\n .space 12\n .endr\n',1)
if args.turn:asm=asm.replace(' mov r12,#0', ' .rept 4\n b .+32\n .space 28\n .endr\n mov r12,#0')
(d/'main.s').write_text(asm);(d/'main.ld').write_text('ENTRY(_start)\nSECTIONS { . = 0x02080000; .text : { *(.text*) } }\n')
w.call(['clang','--target=arm-none-eabi','-mcpu=arm7tdmi','-nostdlib','-fuse-ld=lld','-Wl,-T,'+str(d/'main.ld'),d/'main.s','-o',d/'main.elf'],d,'assemble')
w.call(['llvm-objcopy','-O','binary',d/'main.elf',d/'main.bin'],d,'objcopy')
symbols={n:int(a,16)for a,k,n in(s.split()for s in subprocess.check_output(['llvm-nm',d/'main.elf'],text=True).splitlines()if len(s.split())==3)}
(d/'symbols.json').write_text(json.dumps(symbols,indent=2)+'\n')
files=[d/'arm_pkg.sv']+[p for p in sorted(d.glob('*.sv'))if p.name!='arm_pkg.sv'];(d/'inputs.json').write_text(json.dumps({p.name:w.sha(p)for p in files},indent=2)+'\n')
model=d/'obj/Vtb_cpu';w.call([w.V,'--binary','--timing','--assert','--threads','1','-j','1','-O2','-Wno-fatal','--top-module','tb_cpu','--Mdir',model.parent,*files],d,'build');w.prune(model.parent)
data=bytearray((d/'main.bin').read_bytes());offset=symbols['loop_count']-0x02080000;assert struct.unpack_from('<I',data,offset)[0]==0xe3a0a004;struct.pack_into('<I',data,offset,0xe3a0a010)
image=d/'n16.hex';image.write_text(''.join(f'{v:08x}\n'for v in struct.unpack('<4096I',data+bytes(16384-len(data)))))
prefix=d/'n16-irq1'
text=w.call([model,f'+img={image}','+loops=16','+irq=1',f'+out={prefix}',f'+done={symbols["finished"]:x}',f'+fail={symbols["failed"]:x}',f'+handler={symbols["irq_handler"]:x}'],d,'n16-irq1')
assert'CPU_STORE_ALL_PASS'in text
count=3 if args.turn else 4
counts={int(m[0]):dict(zip('cycles states data writes'.split(),map(int,m[1:])))for m in re.findall(r'CPU_STORE_PASS mode(\d+) cycles(\d+) states(\d+) data(\d+) writes(\d+)',text)};assert len(counts)==count and counts[0]==counts[1]
for suffix in ['state','data','mem','fcomp']:
 before=Path(str(prefix)+'-m0.'+suffix).read_bytes()
 for mode in range(1,count):assert before==Path(str(prefix)+f'-m{mode}.'+suffix).read_bytes(),(mode,suffix)
assert Path(str(prefix)+'-m0.edge').read_bytes()==Path(str(prefix)+'-m1.edge').read_bytes()
writes={m:[]for m in range(count)}
for mode,index,cycle,addr,be,value in re.findall(r'WRITE_ACK mode(\d+) index(\d+) cycle(\d+) addr([0-9a-f]+) be([0-9a-f]+) data([0-9a-f]+)',text):writes[int(mode)].append((index,addr,be,value))
assert all(writes[m]==writes[0]for m in range(count))and len(writes[0])==68
activity={int(m):(int(a),int(t))for m,a,t in re.findall(r'COMBO_ACTIVITY mode(\d+) rejoin(\d+) storeturn(\d+)',text)}
if args.turn:
 tails={int(m):(int(n),int(s))for m,n,s in re.findall(r'TURN_ACTIVITY mode(\d+) N(\d+) S(\d+)',text)}
 assert tails[2][0]>0 and tails[2][1]>0 and activity[2][0]>0 and activity[2][1]>0,(tails,activity)
else:assert activity[3][0]>0 and activity[3][1]>0,activity
(d/'summary.json').write_text(json.dumps(dict(counts=counts,activity=activity,tails=tails if args.turn else None,model_sha256=w.sha(model)),indent=2)+'\n')
w.status('REJOIN +STORETURN MAIN/IRQ terminal PASS');print('COMBO_PASS',counts,activity,flush=True)
