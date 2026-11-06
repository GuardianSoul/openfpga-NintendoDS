#!/usr/bin/env python3
"""Offline source/result/VWR acceptance replay; never starts a model/fit."""
from pathlib import Path
import tarfile,json,hashlib,gzip
with tarfile.open(Path(__file__).with_name('evidence.tar.gz'))as t:data={m.name:t.extractfile(m).read()for m in t.getmembers()if m.isfile()}
m=json.loads(data['manifest.json'])
for f,h in m.items():assert hashlib.sha256(data[f]).hexdigest()==h,f
for mode in ['helper','vendor','caller','wrongbyte','owner','extra','shape']:
 inp=json.loads(data[mode+'/inputs/input.json']);r=json.loads(data[mode+'/receipt.json']);assert r['status']=='PASS_'+mode.upper()and r['peak_bytes']<150*1024*1024
 for f,h in inp['sha256'].items():
  if f!='altera_mf.v':assert hashlib.sha256(data[mode+'/inputs/'+f]).hexdigest()==h,(mode,f)
 for row in r['stages']:assert row['reaped']and row['exit']==(91 if mode in['wrongbyte','owner']and row['label'].endswith('-run')else 0),(mode,row)
for f in ['helper/helper-portable-run.log','helper/helper-native-qis-run.log','vendor/vendor-run.log']:
 log=data[f].decode();assert 'PASS_REGS cycles12386 writes10234 collisions4837 bytechecks98704 imports1'in log and '%Fatal'not in log and 'ERROR'not in log
for backend in ['portable','native-qis']:
 log=data['caller/caller-'+backend+'-run.log'].decode();assert'PASS: 4653087 checks, 0 failures (seed 7, 1783282 cycles)'in log
 assert'SYS_REG_COVERAGE reads111367 writes31191 dma_loads1884 arb_stalls19 collisions159 imports1'in log
extra=data['extra/extra-native-qis-run.log'].decode();assert'PASS: 10162 checks, 0 failures (seed 7, 5081 cycles)'in extra
assert'SYS_REG_COVERAGE reads688 writes12 dma_loads4 arb_stalls19 collisions2 imports1'in extra
assert'// DMA uses restoredSAD+DAD; onlyCNT trigger is rewritten'in data['extra/inputs/tb_sys.cpp'].decode()
for mode,cycle,old,new in [('wrongbyte',188068,'.wd(pending_data[(b%4)*8+:8])','.wd(pending_data[((b+1)%4)*8+:8])'),('owner',187983,'.wa({io_cpu,rg_idx})','.wa({!io_cpu,rg_idx})')]:
 s=data[mode+'/inputs/nds_sys.sv'].decode();assert s.count(old)==1 and s.replace(old,new)==data[mode+'/actual-'+mode+'-mutant.sv'].decode()
 assert f'SYS_REG_PUBLIC_MISMATCH cycle {cycle}'in data[mode+'/'+mode+'-native-qis-run.log'].decode()
 assert "os.environ['SYS_REG_PUBLIC_ONLY']='1'"in data[mode+'/inputs/worker.py'].decode()
ps=json.loads(data['shape/native-shape.json']);assert len(ps)==8
for p in ps:
 dec=lambda x:bytes.fromhex(x.split('h')[1]).decode('ascii')
 assert dec(p['ram_block_type'])=='MLAB'and int(p['width'].split('h')[1],16)==8 and int(p['widthad'].split('h')[1],16)==5 and int(p['numwords'].split('h')[1],16)==32
 for k in ['rdaddress_reg','rdcontrol_reg','outdata_reg']:assert dec(p[k])=='UNREGISTERED'
v=json.loads(data['vwr-reuse/manifest.json'])
for f,h in v.items():assert hashlib.sha256(data['vwr-reuse/'+f]).hexdigest()==h,f
s=data['vwr-reuse/nds_cdc.sv'];assert s==data['production/rtl/pocket/nds_cdc.sv']
assert s.replace(b', parameter RAM_STYLE = "AUTO"',b'').replace(b'(* ramstyle = RAM_STYLE *) ',b'')==data['vwr-reuse/before_nds_cdc.sv']
assert s.replace(b'rdata <= mem[rbin[A-1:0]];',b"rdata <= mem[rbin[A-1:0]] ^ {{(W-1){1'b0}},1'b1};")==data['vwr-reuse/mutant_nds_cdc.sv']
for seed in[1,23,71,91]:assert'VWR_MLAB_EQ_PASS50000Wcycles'in gzip.decompress(data[f'vwr-reuse/equiv-{seed}.log.gz']).decode()
check=json.loads(data['source-check.json'])
for f,h in check['source_sha256'].items():assert hashlib.sha256(data['production/'+f]).hexdigest()==h,f
price=json.loads(data['price1225.json']);assert price['whole']['1225']==[24844,343,61]and price['SYS']==[4.0,84.9,2,0,0,0]and price['VWR']==[45.3,128.9,2,0,0,0]
print('PASS',len(m),'hashed members; SYS helper/fullsystem/firstuse/two publicfaults; acceptedVWR reused without model rerun; actual1225 priced4RAM trade. STA/canonical/DS/game open.')
