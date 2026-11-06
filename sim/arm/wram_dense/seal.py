#!/usr/bin/env python3
"""Seal completed reference-family WRAM jobs; never starts a worker or fit."""
from pathlib import Path
import argparse,gzip,hashlib,io,json,os,resource,tarfile

R=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',type=Path,default=R/'build/wram-dense')
p.add_argument('--output',type=Path,default=R/'docs/results/private-wram-pack-20261102')
a=p.parse_args();D=a.work.resolve();P=a.output.resolve()
os.setpriority(os.PRIO_PROCESS,0,10)
resource.setrlimit(resource.RLIMIT_CPU,(30,30));resource.setrlimit(resource.RLIMIT_AS,(512*1024**2,512*1024**2))
paths={}
def add(name,path):
    assert name not in paths;assert path.is_file();paths[name]=path
def tree(name,path):
    for f in path.rglob('*'):
        if f.is_file():add(name+'/'+f.relative_to(path).as_posix(),f)
for name,source in [('layout','feasibility'),('before-source','before-source'),('snapshots','snapshots'),
    ('primitive','native-feasibility2'),('native','native3'),('fault','native3-merge-mutant'),
    ('late','native3-late'),('architectural','behavioral3'),('cpu','cpu'),
    ('auto','native2'),('auto-late','native2-late'),('auto-fault','native-merge-mutant'),('fits','fits')]:
    tree(name,D/source)
for name in ['area.json','result.json','merged-is-dependency.json','qlint-final.json','qlint-final.log']:
    add(name,D/name)
for f in(R/'sim/arm/wram_dense').glob('*'):
    if f.is_file():add('code/sim/arm/wram_dense/'+f.name,f)
add('code/sim/arm/a7_if_commit/run_cpu.py',R/'sim/arm/a7_if_commit/run_cpu.py')
add('code/sim/arm/stm4_meta/cpu_pair.svh',R/'sim/arm/stm4_meta/cpu_pair.svh')
add('code/tools/fit/resources.py',R/'tools/fit/resources.py')
for name in ['README.md','check.py']:add('result/'+name,P/name)
sha=lambda f:hashlib.file_digest(f.open('rb'),'sha256').hexdigest()
bindings={n:sha(paths[n])for n in ['native/model.vvp','fault/model.vvp','primitive/model.vvp',
    'architectural/obj/Vtb_wram','cpu/obj/Vtb_arm']}
binding=D/'bindings.json';binding.write_text(json.dumps(bindings,indent=2)+'\n');add('bindings.json',binding)
manifest={n:sha(f)for n,f in sorted(paths.items())}
b=(json.dumps(manifest,indent=2)+'\n').encode();expanded=sum(f.stat().st_size for f in paths.values())+len(b)
target=P/'proof.tar.gz.tmp'
with target.open('wb')as out:
    with gzip.GzipFile(filename='',mode='wb',fileobj=out,mtime=0,compresslevel=6)as gz:
        with tarfile.open(fileobj=gz,mode='w|')as t:
            for n,f in sorted(paths.items()):
                x=tarfile.TarInfo(n);x.size=f.stat().st_size;x.mode=f.stat().st_mode&0o777
                with f.open('rb')as data:t.addfile(x,data)
            x=tarfile.TarInfo('manifest.json');x.size=len(b);x.mode=0o644;t.addfile(x,io.BytesIO(b))
os.replace(target,P/'proof.tar.gz')
seal=dict(members=len(paths)+1,expanded_bytes=expanded,SHA256=sha(P/'proof.tar.gz'),
    family='REFERENCE, notcompact',control='1b16d2c0/1188',candidate='149fca92/1193',
    verdict='Retain12M10K tradeoff for627ownedALMs; HOLD main/default; functional+actualfault+CPU PASS; noSTA/DSspeed closure')
(P/'seal.json').write_text(json.dumps(seal,indent=2)+'\n');print(json.dumps(seal,indent=2))
