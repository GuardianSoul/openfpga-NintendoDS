#!/usr/bin/env python3
"""Freeze one measurement packet, preserving failed gates and fixture retries."""
from pathlib import Path
import hashlib,io,json,subprocess,sys,tarfile

R=Path(__file__).resolve().parents[3]
def sha(b):return hashlib.sha256(b).hexdigest()
def main():
    B=Path(sys.argv[1]).resolve();P=Path(sys.argv[2]).resolve()
    P.mkdir(parents=True,exist_ok=True);assert not (P/'evidence.tar.gz').exists()
    snap=json.loads((B/'source.json').read_text());model=json.loads((B/'model.json').read_text())
    assert model['source_sha256']==sha((B/'source.json').read_bytes())
    assert model['binary_sha256']==sha((B/'obj/Vrender_service_tb').read_bytes())
    assert subprocess.check_output(['git','diff','--','rtl'],cwd=R)==b''
    payload={}
    def add(name,p):
        assert name not in payload;payload[name]=p.read_bytes()
    for name in snap['files']:add('model/'+name,B/name)
    for p in B.iterdir():
        if p.is_file()and (p.suffix in ['.json','.log','.csv']):add('runs/'+p.name,p)
    add('model/Vrender_service_tb',B/'obj/Vrender_service_tb')
    for p in (R/'sim/ds/render_service').iterdir():
        if p.is_file():add('harness/'+p.name,p)
    for f in ['sim/ds/ring_deadline/retained_trace_run.py','sim/gpu3d/edge_span_service/runner.py']:
        add('runner/'+Path(f).name,R/f)
    payload['original/nds_gpu3d.sv']=subprocess.check_output(['git','show',snap['source']+':rtl/ds/nds_gpu3d.sv'],cwd=R)
    retries=[]
    for old in sorted((R/'build').glob('render-service-e63-*')):
        if old==B:continue
        row=dict(path=str(old),files={})
        for p in old.iterdir():
            if p.is_file()and (p.suffix=='.log'or p.name in ['source.json','model.json']or p.name.endswith(('.receipt.json','.result.json'))):
                add('retries/'+old.name+'/'+p.name,p);row['files'][p.name]=sha(p.read_bytes())
        retries.append(row)
    payload['retries.json']=(json.dumps(retries,indent=2)+'\n').encode()
    measurements={}
    for action in ['measure','phase2487']:
        r=json.loads((B/(action+'.result.json')).read_text());a=json.loads((B/(action+'.analysis.json')).read_text())
        assert r['PASS'] is False and r['measurement_complete']and r['data_owner_readiness_PASS']and not r['traffic_deadline_PASS']
        assert a['PASS']and a['sha256']==r['trace_sha256']
        measurements[action]=dict(result=r,analysis=a)
    faults={}
    for action in ['native-owner','block-owner','deadline']:
        r=json.loads((B/(action+'.result.json')).read_text());assert r['PASS']and r['returncode']!=0
        assert r['fault']in (B/(action+'.log')).read_text();faults[action]=r
    strict=json.loads((B/'positive.result.json').read_text())
    assert strict['PASS']is False and strict['returncode']!=0
    assert 'TRAFFIC_DEADLINE kind=2 backlog=318'in (B/'positive.log').read_text()
    with tarfile.open(P/'evidence.tar.gz','w:gz',compresslevel=6)as t:
        for name,data in sorted(payload.items()):
            m=tarfile.TarInfo(name);m.size=len(data);m.mode=0o644;m.mtime=0;t.addfile(m,io.BytesIO(data))
    d=dict(packet_integrity_PASS=True,source=snap['source'],source_manifest_sha256=sha((B/'source.json').read_bytes()),
        model=model,production_wrapper_sha256=sha(payload['original/nds_gpu3d.sv']),
        disposition='MEASUREMENT_ONLY_DATA_OWNER_3D_PASS_TRAFFIC_DEADLINE_FAIL_NO_POLICY_ACTIVATION',
        overall_service_deadline_PASS=False,production_RTL_changed=False,guard_or_DS_rule_changed=False,
        game_or_control_rerun=False,fit_run=False,measurements=measurements,actual_faults_caught=faults,strict_result=strict,
        archive_sha256=sha((P/'evidence.tar.gz').read_bytes()),members_sha256={k:sha(v)for k,v in payload.items()},
        retry_notes=[
            'v1: missing observation define; fixed test compile flag.',
            'v2/v3: oracle assumed ideal renderer always leads; actual final-pass clear contention invalidates that assumption. Completed generation-tagged oracle frames replace the assumption; exact values unchanged.',
            'v4/v10: data smoke only. Incorrect preliminary due/traffic fixture; v10 video writes paced128 words/1400SYS, corrected to128/4260SYS. These runs have no service deadline acceptance.',
            'v9: native-owner and row2 faults caught; block-owner first caught original no-inflight guard, initially misclassified by expected text. Final model repeats all three actual faults with precise classifications.',
            'final strict capture backlog318 preserved. Separate measure/phase records all new traffic-monitor violations; every original DUT and independent data/owner/3D/refresh/FIFO guard stays fatal.',
            'Final native-owner first admission failed shared disk floor. No worker launched. Lossless own superseded-binary compaction and changed live reservations preceded successful readmission.'],
        next_action='No urgency correction qualified: all producer deadlines in this small scene have large slack. Use an explicitly bounded late-producer dependency case before evaluating a default-off policy; preserve these failed shared-traffic gates. Root owns current combined native/game/area gates.')
    (P/'result.json').write_text(json.dumps(d,indent=2)+'\n')
    print('FROZEN',len(payload),'members',round((P/'evidence.tar.gz').stat().st_size/2**20,2),'MiB; overall_service_deadline_PASS=false')
if __name__=='__main__':main()
