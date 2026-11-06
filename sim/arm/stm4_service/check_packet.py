#!/usr/bin/env python3
"""Replay the STM4 observable evidence without rerunning any model."""
import argparse
import contextlib
from fractions import Fraction
import hashlib
import importlib.util
import importlib.machinery
import json
from pathlib import Path
import re
import sys
import tarfile
import tempfile


def digest(p):
    with p.open('rb')as f:return hashlib.file_digest(f,'sha256').hexdigest()


def replay(root,manifest):
    paths=manifest['paths']
    def path(name):return root/'objects'/paths[name]['sha256']
    def j(name):return json.loads(path(name).read_text())
    def resolve(original):
        for prefix,label in sorted(manifest['original_prefixes'].items(),key=lambda x:-len(x[0])):
            if original==prefix or original.startswith(prefix+'/'):
                name=label+original[len(prefix):]
                assert name in paths,(original,name)
                return path(name)
        raise AssertionError(('unmapped frozen input',original))
    def same(a,b):assert paths[a]['sha256']==paths[b]['sha256'],(a,b)
    def pins(stem):
        expected={0:[],1:[]};actual={0:[],1:[]}
        for line in path(stem+'.physical').read_text().splitlines():
            v=line.split()
            if v[1]!='1':continue
            addr,be,data=int(v[2],16),int(v[3],16),int(v[4],16)
            for chip in [0,1]:
                hb=(be>>(chip*2))&3;mask=(255 if hb&1 else 0)|(65280 if hb&2 else 0)
                if hb:expected[chip].append((addr,(data>>(chip*16))&mask,hb))
        for line in path(stem+'.pinwords').read_text().splitlines():
            chip,t,addr,data,be=line.split(',');hb=int(be,16);mask=(255 if hb&1 else 0)|(65280 if hb&2 else 0)
            actual[int(chip)].append((int(addr,16),int(data,16)&mask,hb))
        assert expected==actual,('physical pin payload/BE/address/order',stem)
        return {str(k):len(v)for k,v in actual.items()}
    # Every actual model-input receipt is checked against its archived bytes;
    # names preserve preceding, candidate and deliberately mutated sources.
    model_receipts=0
    for name in paths:
        if name.endswith(('/model.json','-model.json')):
            rec=j(name)
            if 'inputs'not in rec:continue
            for original,h in rec['inputs'].items():
                f=resolve(original)if original.startswith('/')else path('/'.join(name.split('/')[:2])+'/'+original)
                assert digest(f)==h,original
            model_receipts+=1
    C='component/'
    B=C+'stm4-service-candidate-v1/'
    N=C+'stm4-service-candidate-v3/'
    summary=j(N+'summary.json');assert len(summary)==8
    retired=data=0;physical={0:0,1:0}
    for key,values in summary.items():
        assert set(values)=={'before','off','hold','group'}
        old=B+'before/'+key;off=N+'off/'+key;new=N+'group/'+key
        for suffix in ['state','data','edge','physical','pins','pinwords']:same(old+'.'+suffix,off+'.'+suffix)
        for suffix in ['state','data']:same(old+'.'+suffix,new+'.'+suffix)
        assert len(path(new+'.state').read_text().splitlines())==values['group']['states']
        assert len(path(new+'.data').read_text().splitlines())==values['group']['data']
        counts=pins(new);assert counts==values['group']['pinwords']
        retired+=values['group']['states'];data+=values['group']['data']
        for k,v in counts.items():physical[int(k)]+=v
    def slope(role):return Fraction(summary['n16-o0-p0-phase0-pause0'][role]['body']-summary['n4-o0-p0-phase0-pause0'][role]['body'],1536)
    assert slope('before')==slope('off')==slope('hold')==24 and slope('group')==15
    fault=j(C+'stm4-service-turn-fault-v1/complete.json')
    assert fault['quiet_A7_per_STM4']=='15'
    assert 'ARM7 self-check failed'in path(C+'stm4-service-turn-fault-v1/fault.log').read_text()
    for role,token in [('repeat-held','write/owner cardinality'),('wrong-payload','ARM7 self-check failed')]:
        key='n4-o0-p0-phase0-pause1'if role=='repeat-held'else'n4-o0-p0-phase0-pause0'
        assert token in path(B+role+'/'+key+'.log').read_text()
    fallback=C+'stm4-service-fallback-v2/'
    f=j(fallback+'complete.json');edges=0
    for phase in [0,1,4973]:
        text=path(fallback+f'normal/phase{phase}.log').read_text()
        assert text.count('PASS group leaf ifs1 writes1288 reads1124 resets9 groups287 accepted1288 physical1288')==3
        edges+=int(re.search(r'FALLBACK_EQ_PASS edges(\d+)',text)[1])
    assert 'FALLBACK_EQ'in path(fallback+'mutant/phase0.log').read_text()
    reset=C+'stm4-service-cpu-reset-v4/'
    resets=j(reset+'complete.json');assert len(resets['results'])==13
    for key,value in resets['results'].items():
        if key=='actual_fault':continue
        if 'reused'in value:
            original=value['reused'];prefix=next((label+original[len(pre):]for pre,label in manifest['original_prefixes'].items()if original.startswith(pre+'/')),None)
            assert prefix is not None
            stem=prefix
        else:stem=reset+'normal/'+key
        assert pins(stem)==value['pinwords']
        text=path(stem+'.stm4').read_text();assert text.count('RESET_BEGIN')==text.count('RESET_DRAIN')==1
        assert 'STM4_ENDPOINT_PASS'in path(stem+'.log').read_text()
    assert 'STM4 physical old-owner mismatch'in path(reset+'wrong-reset-owner/reset4-phase0.log').read_text()
    observer=C+'stm4-group-observer-v1/'
    observer_result=j(observer+'complete.json')
    assert paths[observer+'group_observer.sv']['sha256']==observer_result['observer_sha256']
    tuples=observer_result['results']['normal']['packets']
    assert any(x['req_group']==0 and x['req_cpu']==1 for x in tuples)
    assert any(x['req_group']==1 and x['req_cpu']==1 and x['expected_cpu']==1 and x['count']==4 for x in tuples)
    assert any(x['req_group']==1 and x['req_cpu']==0 and x['expected_cpu']==0 and x['count']==8 for x in tuples)
    for role,token in [('wrong-class','STM4_OBSERVER_VALID_GROUP_CLASS_FAIL'),('wrong-count','STM4_OBSERVER_VALID_CPU_COUNT_FAIL')]:
        assert token in path(observer+role+'/run.log').read_text()
    result=dict(status='PASS component evidence; native pending',models_with_checked_inputs=model_receipts,
                component=dict(cases=8,retired_states=retired,CPU_data=data,physical_halfword_writes=physical,quiet_A7_before=24,quiet_A7_after=15,DS_A7=15),
                fallback=dict(compared_edges=edges,phases=3,three_lanes_per_phase=True,words_per_lane=1288,reads_per_lane=1124,reset_epochs_per_lane=9),reset_cases=12,
                actual_faults=['repeated held P7 admission','grouped payload','idle-edge physical address','DMA fallback class','CPU-reset posted owner','valid-group CPU class','valid-group CPU count'],
                rejected_fault_controls=['setup-data-only XOR is overwritten before live payload','CPU reset after service ACK cannot erase a completed posted owner'])
    if manifest['stage']!='COMPLETE_COMPONENT_AND_NATIVE':return result
    source=j('native61/source-manifest.json');profile=j('native61/profile.json');model=j('native61/model.json')
    assert source['source']==model['source']=='5f57d8a9ff62e53ac71502ef5f277ac48517caf1'
    assert profile==model['profile'] and len(profile)==61 and profile['A7_STM4_SERVICE']==1
    assert {k:v for k,v in profile.items()if k!='A7_STM4_SERVICE'}==j('native60-control/profile.json')
    assert paths['native61/model/Vtb_ds_pocket']['sha256']==model['sha256']
    for n,h in source['files'].items():assert paths['native61/source/'+n]['sha256']==h,n
    component_inputs=j(N+'group/model.json')['inputs']
    composition={n.removeprefix('candidate/source/'):h for n,h in component_inputs.items()if n.startswith('candidate/source/')}
    assert len(composition)==16
    for n,h in composition.items():assert source['files'][n]==h,n
    for n,h in model['host_sha256'].items():assert paths['native61/'+n]['sha256']==h,n
    same('native61/host-overlay/stm4_group_observer.sv',observer+'group_observer.sv')
    public=j('native61/public-fault.json');assert public['caught']['fault']=='PUBLIC_TAG_DISCONNECT'
    assert public['caught']['expected_tag']&4 and public['caught']['observed_tag']==0 and public['model_sha256']==model['sha256']
    assert 'NATIVE61_STM4_PUBLIC_TAG_DISCONNECT'in path('native61/runs/ds30-fault/run.log').read_text()
    fault_process=j('native61/runs/ds30-fault/run.process.json')
    assert fault_process['reaped']and fault_process['exit']!=0 and fault_process['NI']==10
    assert '+stm4_route_mutant'in fault_process['argv']
    assert fault_process['argv'][0]==j('native61/runs/ds30/run.process.json')['argv'][0]
    # Restore only the small DS30 checker/prepared file tree for its imports.
    with tempfile.TemporaryDirectory(prefix='stm4-small-replay-',dir=root)as temp:
        small=Path(temp)
        for name in paths:
            if name.startswith('native61/ds30/'):
                target=small/name.removeprefix('native61/');target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(path(name).read_bytes())
        sys.path.insert(0,str(small/'ds30'))
        def module(name,f):
            loader=importlib.machinery.SourceFileLoader(name,str(f));spec=importlib.util.spec_from_loader(name,loader)
            m=importlib.util.module_from_spec(spec);loader.exec_module(m);return m
        observer=module('stm4_ds30_packet',small/'ds30/check_observer.py')
        capture=small/'capture'
        for suffix in ['.jsonl','.main.bin','.ping.bodies.bin','.endpoint.bodies.bin']:
            Path(str(capture)+suffix).write_bytes(path('native61/runs/ds30/ds30-capture'+suffix).read_bytes())
        with contextlib.redirect_stdout(sys.stderr):
            ds30=observer.validate(capture,small/'ds30',path('native61/runs/ds30/manifest.json'),path('native61/runs/ds30/run.log'))
        saved=j('native61/runs/ds30/result.json');assert ds30=={k:v for k,v in saved.items()if k!='STM4_activity'}
        guard=module('stm4_native_guard',path('native61/native_guard.py'))
        for name,count in [('unita7',22),('unitmem',32)]:
            r=guard.validate(path('native61/runs/'+name+'/run.log').read_text(),count,name)
            assert r['accepted']and json.loads(json.dumps(r))==j('native61/runs/'+name+'/result.json')['guards']
    comparison=[];before=j('native60-control/runs/ds30/result.json')['rows']
    assert len(before)==len(ds30['rows'])==31
    for a,b in zip(before,ds30['rows']):
        assert(a['kernel'],a['arg'],a['DS_x100'])==(b['kernel'],b['arg'],b['DS_x100'])
        comparison.append(dict(kernel=b['kernel'],arg=b['arg'],native60=int(a['arm7_cycles_per_op_x100']),native61=int(b['arm7_cycles_per_op_x100']),DS_x100=b['DS_x100']))
    for name in ['ds30','unita7','unitmem']:
        rec=j('native61/runs/'+name+'/manifest.json');assert rec['source']==source['source']and rec['model_sha256']==model['sha256']and rec['profile']==profile
        old=j('native60-control/runs/'+name+'/manifest.json');assert rec['ROM_sha256']==old['ROM_sha256']and rec['expanded_sha256']==old['expanded_sha256']
        text=path('native61/runs/'+name+'/run.log').read_text();assert text.count('NATIVE61_STM4_ROUTE_PASS')==1 and 'NATIVE61_STM4_PUBLIC_FAULT_ARMED'not in text
        proc=j('native61/runs/'+name+'/run.process.json');assert proc['exit']==0 and proc['reaped']and proc['NI']==10
    activity=j('native61/runs/ds30/result.json')['STM4_activity']
    assert {activity[k]for k in ['CPU_consumes','P7_admissions','P7_service_ACKs','fabric_grants','PSRAM_captures','physical_words']}=={28160}
    assert activity['physical_groups']==7040 and activity['idle_word_turns']==21120
    # Preserve all canonical values against the immediately preceding model
    # and the DS targets in the exact frozen production source. Sentinel
    # rows are checked as values, without inventing timing units for them.
    scorecard=module('stm4_native_scorecard',path('native61/source/tools/scorecard/scorecard.py'))
    canonical_comparison={}
    for name,count in [('unita7',22),('unitmem',32)]:
        old=j('native60-control/runs/'+name+'/result.json')['guards']['values']
        new=j('native61/runs/'+name+'/result.json')['guards']['values']
        assert set(old)==set(new)=={str(i)for i in range(count)}
        targets=scorecard.ROWS[name];assert len(targets)==count
        rows=[]
        for i,(key,description,target,unit,run,owner)in enumerate(targets):
            a,b=old[str(i)],new[str(i)]
            rows.append(dict(index=i,key=key,description=description,native60=a,native61=b,DS_x100=target,unit=unit,DS_run=run,
                             delta=b-a,core_over_DS_fraction=str(Fraction(b,target))if target else None))
        canonical_comparison[name]=rows
    result.update(status='PASS component and three affected native observable guards; timing values retained separately',source=source['source'],model_sha256=model['sha256'],native_DS30=comparison,
                  native_canonical={name:j('native61/runs/'+name+'/result.json')['guards']['values']for name in ['unita7','unitmem']},
                  native_canonical_comparison=canonical_comparison,
                  native_STM4_activity={name:j('native61/runs/'+name+'/result.json')['STM4_activity']for name in ['ds30','unita7','unitmem']})
    stm=canonical_comparison['unita7'][13]
    assert stm['key']=='STM4MAIN'and(stm['native60'],stm['native61'],stm['DS_x100'])==(2798,3202,1500)
    result['enabled_integration']='REJECTED: canonical STM4 regresses2798->3202/DS1500; quiet1500/DS1500 remains a scoped observation'
    result['public_fault']=public
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('packet',type=Path);a=p.parse_args()
    if a.packet.is_dir():
        root=a.packet.resolve();manifest=json.loads((root/'packet-manifest.json').read_text())
        for h in {v['sha256']for v in manifest['paths'].values()}:assert digest(root/'objects'/h)==h,h
        print(json.dumps(replay(root,manifest),indent=2));return
    with tempfile.TemporaryDirectory(prefix='stm4-packet-',dir=a.packet.resolve().parent)as temp:
        root=Path(temp);(root/'objects').mkdir()
        with tarfile.open(a.packet,'r|*')as tar:
            first=tar.next();assert first.name=='packet-manifest.json';manifest=json.load(tar.extractfile(first))
            expected={v['sha256']for v in manifest['paths'].values()};seen=set()
            while m:=tar.next():
                assert m.isfile()and re.fullmatch(r'objects/[0-9a-f]{64}',m.name)
                h=m.name.split('/')[1];assert h in expected and h not in seen;seen.add(h)
                with tar.extractfile(m)as src,(root/m.name).open('wb')as dst:
                    while chunk:=src.read(1024*1024):dst.write(chunk)
                assert digest(root/m.name)==h
            assert expected==seen
        result=replay(root,manifest);result['archive_sha256']=digest(a.packet);print(json.dumps(result,indent=2))


if __name__=='__main__':main()
