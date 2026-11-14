#!/usr/bin/env python3
"""Compare measured accepted geometry and service; no shifted game/frame oracle."""
import argparse
from collections import defaultdict, Counter
import hashlib
import json
from pathlib import Path

SHA=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()


def records(run):
    rows=defaultdict(list);times=defaultdict(list);frames={};done={}
    with (run/'service.csv').open() as f:
        for line in f:
            r=line.rstrip().split(',')
            if r[0]=='WORK':
                cy,g,y,typ=map(int,r[1:5]);payload=int(r[5],16)
                assert typ!=3 or payload==0
                rows[g,y].append(bytes([typ])+payload.to_bytes(16,'big'));times[g,y].append(cy)
            elif r[0]=='FRAME':frames[int(r[2])]=int(r[1])
    with (run/'observer.csv').open() as f:
        for line in f:
            r=line.rstrip().split(',')
            if r[0]=='DONE':done[int(r[3]),int(r[4])]=[int(r[1]),*map(int,r[5:9])]
    return rows,times,frames,done


def report(default,private):
    a,at,af,ad=records(default);b,bt,bf,bd=records(private)
    aj=json.loads((default/'service-analysis.json').read_text());bj=json.loads((private/'service-analysis.json').read_text())
    assert aj['config']['NX2']==0 and bj['config']['NX2']==1
    assert all(aj['exact_endpoint_control'].values())and all(bj['exact_endpoint_control'].values())
    row_results=[];gen=defaultdict(Counter)
    for g,y in sorted(a.keys()|b.keys()):
        x,z=a.get((g,y),[]),b.get((g,y),[]);same=x==z;gen[g]['rows_equal'if same else'rows_different']+=1
        first=next((i for i,(left,right)in enumerate(zip(x,z))if left!=right),min(len(x),len(z)))
        witness=None if same else dict(index=first,default=x[first].hex()if first<len(x)else None,private=z[first].hex()if first<len(z)else None)
        row_results.append(dict(generation=g,y=y,default_records=len(x),private_records=len(z),same_accepted_geometry=same,default_sha256=hashlib.sha256(b''.join(x)).hexdigest(),private_sha256=hashlib.sha256(b''.join(z)).hexdigest(),first_difference=witness,default_first_accept=at[g,y][0]if x else None,private_first_accept=bt[g,y][0]if z else None,default_last_accept=at[g,y][-1]if x else None,private_last_accept=bt[g,y][-1]if z else None))
    configs=[]
    for run in [default,private]:
        data={}
        for line in (run/'service.csv').read_text().splitlines():
            r=line.split(',')
            if r[0]=='FRAME':data[int(r[2])]=r[4:]
        configs.append(data)
    matrix=[]
    for g in sorted(gen):
        x=b''.join(bytes([y])+r for (gg,y),entries in sorted(a.items())if gg==g for r in entries)
        z=b''.join(bytes([y])+r for (gg,y),entries in sorted(b.items())if gg==g for r in entries)
        old=aj['generations'].get(str(g),{});new=bj['generations'].get(str(g),{})
        def stalls(done):
            result=Counter()
            for (gg,y),v in done.items():
                if gg!=g:continue
                result.update(rows=1,wait17=v[1],wait19=v[2],ll20=v[3],issued_pixels=v[4])
            return dict(result)
        raw_left=configs[0].get(g);raw_right=configs[1].get(g)
        config_compare=None
        if raw_left is not None and raw_right is not None:
            delta=int(raw_left[0],16)^int(raw_right[0],16)
            config_compare=dict(default=raw_left,private=raw_right,raw_equal=raw_left==raw_right,DISPCNT_changed_bits=f'{delta:04x}',equal_except_status_bit13=raw_left[1:]==raw_right[1:] and delta in [0,0x2000],scope='Recorded DISPCNT/alpharef/clear_attr1/fog_color subset, latched at VBlank. Bit13 is the source polygon/vertex overflow status (gpu3d_geom, nds_io); not a claim of complete renderer/texture/CPU input equality.')
        matrix.append(dict(generation=g,recorded_frame_config=config_compare,same_accepted_geometry=x==z,default_geometry_sha256=hashlib.sha256(x).hexdigest(),private_geometry_sha256=hashlib.sha256(z).hexdigest(),row_comparison=dict(gen[g]),frame_start_delta_SYS=bf[g]-af[g]if g in af and g in bf else None,default_row_stalls=stalls(ad),private_row_stalls=stalls(bd),default_actual_service=old,private_actual_service=new))
    lookup={(r['generation'],r['y']):r for r in row_results}
    cohort=bj['strict_full_to_render_late_actual_service'];n=sum(lookup[r['generation'],r['y']]['same_accepted_geometry']for r in cohort)
    result=dict(kind='PAIRED_PASSIVE_NEW_SERVICE_AND_CANONICAL_GEOMETRY_MEASUREMENT',production='1d90 RTL, NX2 only private; no production edit',default=str(default),private=str(private),service_sha256=dict(default=SHA(default/'service.csv'),private=SHA(private/'service.csv')),generation_matrix=matrix,row_comparisons=row_results,strict638_accepted_geometry=dict(rows=len(cohort),same=n,different=len(cohort)-n),disposition='No buffer, priority change, fit, activation or scene-speed credit from delivery counters. Preserve exact endpoint controls and separate changed input workload from shared-service delay.',limits='Exact store-to-raster accepted type/payload vectors, canonical type3=0 as existing G3D_EQ. Matching geometry does not establish identical texture/palette contents or full CPU/game state. Texture/palette fingerprints in the service probe interleave request addresses and return values; different schedules can change those fingerprints even if separate payload sequences match. Per-stage wait counters overlap and cannot be added as a causal timing partition. Initial/trailing partial generations remain explicit; no offset, percentage margin or image search.')
    p=private/'paired-service-and-geometry.json';encoded=json.dumps(result,indent=2)+'\n'
    if p.exists():assert p.read_text()==encoded,'refuse overwrite'
    else:p.write_text(encoded)
    print('PAIRED_CANONICAL_WORK',result['strict638_accepted_geometry'])
    for r in matrix:print('GEN',r['generation'],'equal_work',r['same_accepted_geometry'],'row_comparison',r['row_comparison'],'frame_delta',r['frame_start_delta_SYS'])
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--default',required=True,type=Path);p.add_argument('--private',required=True,type=Path);a=p.parse_args();report(a.default.resolve(),a.private.resolve())
