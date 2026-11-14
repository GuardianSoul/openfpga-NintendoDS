#!/usr/bin/env python3
"""Bounded read-only analysis with explicit coordinator job reservations."""
from pathlib import Path
import json
import shutil
import sys
import time

R=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(R/'sim/gpu3d/edge_span_service'))
import runner

def admission(path,growth):
    policy=json.loads(runner.POLICY.read_text())
    reservations=[]
    for p in (runner.MAIN/'build/coordinator/units').glob('*.json'):
        if p==runner.STATUS:continue
        try:d=json.loads(p.read_text())
        except (ValueError,OSError):continue
        workers=d.get('workers',[])
        if not isinstance(workers,list):continue
        active=[w for w in workers if isinstance(w,dict) and w.get('host','').startswith('Desktop')]
        if not active:continue
        n=d.get('disk_growth_bound_bytes')
        basis='owner.disk_growth_bound_bytes'
        if n is None:
            peaks=[int(w['peak_new_bytes']) for w in active if 'peak_new_bytes' in w]
            if peaks:
                # Explicit controller-job reservation covers its subprocesses.
                n=sum(peaks);basis='sum explicit worker.peak_new_bytes'
            else:
                n=policy['default_build_peak_new_bytes'] if 'BUILD' in d.get('phase','').upper() else policy['simulation_output_cap_bytes']
                basis='legacy conservative fallback'
        reservations.append(dict(owner=p.stem,bytes=n,basis=basis,status_sha256=runner.sha(p)))
    free=shutil.disk_usage(R).free
    mem=int(next(x.split()[1] for x in Path('/proc/meminfo').read_text().splitlines() if x.startswith('MemAvailable:')))*1024
    reserved=sum(r['bytes'] for r in reservations)
    receipt=dict(at=time.time(),free_bytes=free,mem_available_bytes=mem,other_reservations=reservations,
        declared_growth_bound_bytes=growth,floor_bytes=policy['floor_bytes'],policy_sha256=runner.sha(runner.POLICY),
        admitted=free-reserved-growth>=policy['floor_bytes'] and mem>=12*1024**3)
    runner.put(path,receipt)
    if not receipt['admitted']:
        runner.status(phase='RENDER_TRACE_RESOURCE_BLOCKED',workers=[],disk_growth_bound_bytes=0,
            resource_blocker=f'diskfree{free}/other{reserved}/growth{growth}/floor{policy["floor_bytes"]};RAM{mem}')
        raise RuntimeError('declared-growth admission failed')
    return receipt

def main():
    B=Path(sys.argv[1]).resolve();B.mkdir(parents=True,exist_ok=True)
    runner.admission=admission
    rc,log=runner.worker(B,'retained-trace',['python3',R/'sim/ds/ring_deadline/retained_trace.py',B],growth=64*1024**2,seconds=180)
    print(log[-3500:]);assert rc==0,rc

if __name__=='__main__':main()
