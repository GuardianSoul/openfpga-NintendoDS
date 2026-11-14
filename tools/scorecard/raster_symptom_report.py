#!/usr/bin/env python3
"""Read fixed-window symptom evidence; never aligns/shifts a pass oracle."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re

import numpy as np
from PIL import Image


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def motion(shots):
    rows=[]
    for (ka,pa),(kb,pb) in zip(shots,shots[1:]):
        a=np.asarray(Image.open(pa)).astype(np.int16)
        b=np.asarray(Image.open(pb)).astype(np.int16)
        regions=[]
        for name,y0,y1 in [('top',0,192),('bottom',192,384),('upper-top',0,96),('lower-bottom',256,384)]:
            costs={str(d):round(float(np.mean(np.abs(a[y0+8:y1-8:2,::4]-b[y0+8+d:y1-8+d:2,::4]))),6)
                   for d in range(-8,9)}
            flat_a=bool(np.all(a[y0:y1]==a[y0,0]));flat_b=bool(np.all(b[y0:y1]==b[y0,0]))
            best=min(costs,key=lambda d:(costs[d],abs(int(d)),int(d)))
            regions.append(dict(region=name,changed_pixels=int(np.count_nonzero(np.any(a[y0:y1]!=b[y0:y1],axis=2))),
                                previous_spatially_flat=flat_a,current_spatially_flat=flat_b,
                                adjacent_dy_min_sad=None if flat_a or flat_b else best,costs=costs))
        rows.append(dict(previous_frame=ka,frame=kb,regions=regions))
    return rows


def analyze(run,inventory):
    text=(run/'run.log').read_text(errors='replace')
    window=re.search(r'ROBS_WINDOW release=(\d+) target=(\d+) frames=(\d+) enable=(\d+) fault=(\d+)',text)
    info=json.loads((run/'run.json').read_text()) if (run/'run.json').exists() else {}
    result=dict(path=str(run),run=info,log_sha256=sha(run/'run.log'),complete=False)
    result['injected_actual_interface_fault']=re.findall(r'ROBS_INJECT (.*)',text)
    result['check_failures']=re.findall(r'ROBS_ACTUAL_FAULT_OR_DATA_ERROR (.*)',text)
    result['harness_errors']=[x for x in text.splitlines() if '%Error' in x or '%Fatal' in x or x.startswith('TIMEOUT')]
    result['initial_memory_readback_pass']='ROBS_IMPORT_MEMORY_PASS' in text
    dig=re.search(r'ROBS_DIGEST (\w+) events=(\d+) errors=(\d+) fault_fired=(\d+)',text)
    if dig:result['functional_digest']=dict(value=dig[1],events=int(dig[2]),errors=int(dig[3]),fault_fired=int(dig[4]))
    capdig=re.search(r'RCAP_DIGEST (\w+) words=(\d+) wait=(\d+)',text)
    if capdig:result['capture_digest']=dict(value=capdig[1],words=int(capdig[2]),wait=int(capdig[3]))
    for marker,key in [('RCAP_FULLDATA','full_request_data'),('RCAP_CONSUMEDFULL','consumed_full_data')]:
        m=re.search(marker+r' checks=(\d+) errors=(\d+)',text)
        if m:result[key]=dict(checks=int(m[1]),errors=int(m[2]))
    fog=re.search(r'RCAP_FOG eligible=(\d+) changed=(\d+) density_min=(-?\d+) density_max=(-?\d+)',text)
    if fog:result['fog_effect']=dict(eligible=int(fog[1]),changed=int(fog[2]),density_min=int(fog[3]),density_max=int(fog[4]))
    if not window:return result
    release,target,n,enable,fault=map(int,window.groups())
    result['window']=dict(release=release,target=target,fixed_frames=n,observer_enable=enable,fault=fault)
    rows=[];ready=[];done=[];totals=None;owners=None;masks={};pix=0
    p=run/'observer.csv'
    if p.exists():
        result['observer_sha256']=sha(p)
        with p.open() as f:
            for r in csv.reader(f):
                if not r or r[0].startswith('#'):continue
                if r[0]=='ROW':
                    vals=list(map(int,r[1:]));names=['cycle','video_frame','generation','y','have','partial','render_late','delivery_late','final_rows','started_rows','done_cycle','full_visible_edge','partial_visible_edge','screen_swap','two_d_late']
                    x=dict(zip(names,vals));x['frame']=x['video_frame']-release+1
                    if 1<=x['frame']<=n:
                        x['kind']=('full' if x['have'] and not x['partial'] else 'partial' if x['have']
                                   else 'delivery-late' if x['final_rows']>x['y'] else 'render-late' if x['render_late']
                                   else 'render-not-started' if x['started_rows']<=x['y'] else 'unready-unattributed')
                        x['full_slack_SYS']=None if x['full_visible_edge']<0 else x['cycle']-x['full_visible_edge']
                        rows.append(x)
                elif r[0]=='READY':ready.append(list(map(int,r[1:])))
                elif r[0]=='DONE':done.append(list(map(int,r[1:])))
                elif r[0]=='TOTAL':totals=list(map(int,r[1:]))
                elif r[0]=='OWNERS':owners=list(map(int,r[1:]))
                elif r[0]=='MASK':masks[r[1]]=int(r[2])
                elif r[0]=='PIX':pix+=1
    result['rows']=rows
    result['counts']={name:sum(x['kind']==name for x in rows) for name in ['full','partial','render-late','delivery-late','render-not-started','unready-unattributed']}
    result['owners_wrong_row_wrong_gen_unknown_prefix']=owners
    total_names=['cycles','generation','row_requests','hint_offers','hint_admissions','hint_drops','hint_scans','hint_block_launches','queued_demand_block_launches','head_block_launches','LLR_reads','LLR_denied','partial_publications','texture_requests','texture_returns','palette_requests','palette_returns','texture_blocks','palette_blocks','two_d_priority_wait_SYS','ring_read_ack_wait_SYS','finalpass_hold_SYS','two_d_late_pulses']
    result['totals']=dict(zip(total_names,totals or []))
    result['stall_masks']=masks
    result['stall_mask_order_MSB_to_LSB']=['lin_hold','AREA_phase','hold15','wait17','take17','hold17','wait19','take19','hz20','ll20']
    result['consumed_3d_pixel_records']=pix
    result['completed_render_rows']=len(done)
    result['row_publications']=len(ready)
    cap=run/'capture.csv'
    if cap.exists():
        captures={};jobs=[];affine=[];io=[]
        with cap.open() as f:
            for c in csv.reader(f):
                if not c or c[0].startswith('#'):continue
                if c[0]=='CAP':
                    vf,gen,y=int(c[2]),int(c[3]),int(c[4]);addr=int(c[6],16);bank=addr>>16
                    key=(vf-release+1,gen,y,bank)
                    q=captures.setdefault(key,dict(words=0,first_addr=addr,last_addr=addr,source_3d=int(c[10]),capcnt=c[8],width=int(c[9])))
                    q['words']+=1;q['last_addr']=addr
                elif c[0]=='JOB':jobs.append(c[1:])
                elif c[0]=='AFF':affine.append(c[1:])
                elif c[0]=='IO':io.append(c[1:])
        result['capture']=dict(sha256=sha(cap),rows=[dict(frame=k[0],generation=k[1],y=k[2],bank=k[3],**v) for k,v in captures.items()],jobs=jobs,affine=affine,io_writes=io)
    result['reference_alignment']='Fixed reference frame clean_export_frame+k and first complete Pocket video frame k after import release, offset pinned from clean.txt before measurement. No nearest-frame or image translation used. Includes import/display transition and known pipeline latency; symptom comparison, not DS acceptance.'
    shots=[]
    for k in range(1,n+1):
        # write_ppm's nshot equals v_frames before its increment.
        path=run/'shots'/f'f{release+k-1:03d}.ppm'
        if path.exists():shots.append((k,path))
    result['fixed_shots']=[dict(frame=k,path=str(p),sha256=sha(p)) for k,p in shots]
    result['complete']=len(shots)==n and 'video:' in text and dig is not None and not result['check_failures'] and not result['harness_errors']
    if shots:
        result['motion_diagnostic']=motion(shots)
        if info:
            scene=inventory['scenes'][info['scene']]
            ref=Path(scene['retained'])/'mel/shots'
            e0=scene.get('clean_export_frame',int((Path(scene['retained'])/'exp/clean.txt').read_text().split()[1]))
            refs=[(k,ref/f'f{k+e0:06d}.ppm') for k,_ in shots]
            result['reference_motion_diagnostic']=motion(refs)
            pairs=[]
            for (k,ours),(_,reference) in zip(shots,refs):
                a=np.asarray(Image.open(ours));b=np.asarray(Image.open(reference))
                if a.shape!=b.shape:raise RuntimeError(f'screen geometry mismatch {ours}')
                error=np.max(np.abs(a.astype(np.int16)-b.astype(np.int16)),axis=2)
                dark_a=np.mean(np.max(a,axis=2)<=8,axis=1)
                dark_b=np.mean(np.max(b,axis=2)<=8,axis=1)
                pairs.append(dict(frame=k,raw_differing_pixels=int(np.count_nonzero(error)),
                                  rgb555_projection_differing_pixels=int(np.count_nonzero(np.any((a>>3)!=(b>>3),axis=2))),
                                  rgb666_projection_differing_pixels=int(np.count_nonzero(np.any((a>>2)!=(b>>2),axis=2))),
                                  reference_sha256=sha(reference),
                                  excess_dark_row_candidates=np.flatnonzero((dark_a>.9)&(dark_b<.5)).tolist()))
            result['fixed_pairs']=pairs
    result['limits']='No all-six/full-DS/speed/save/state acceptance. Owner provenance before first observed generation can be unknown. Adjacent-frame dy costs characterize motion only; no shifted image contributes to a pass. Hint launch counters do not prove useful fills or saved deadlines.'
    return result


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('run',type=Path)
    ap.add_argument('--inventory',type=Path)
    ap.add_argument('--inverse',type=Path,help='same-model observer-disabled run; exact functional/image comparison')
    a=ap.parse_args()
    metadata=json.loads((a.run/'run.json').read_text()) if (a.run/'run.json').exists() else {}
    inv=a.inventory or Path(metadata.get('inventory_path',a.run.parent/'inventory.json'))
    result=analyze(a.run,json.loads(inv.read_text()))
    if a.inverse:
        other=analyze(a.inverse,json.loads(inv.read_text()))
        mine={x['frame']:x['sha256'] for x in result.get('fixed_shots',[])}
        theirs={x['frame']:x['sha256'] for x in other.get('fixed_shots',[])}
        same_model=result['run'].get('model_sha256')==other['run'].get('model_sha256')
        same_inputs=result['run'].get('inventory_sha256')==other['run'].get('inventory_sha256')
        result['observer_inverse']=dict(path=str(a.inverse),same_model=same_model,same_inputs=same_inputs,
            functional_digest_equal=result.get('functional_digest')==other.get('functional_digest'),
            capture_digest_equal=result.get('capture_digest')==other.get('capture_digest'),
            fixed_images_equal=mine==theirs,compared_frames=len(mine),
            passed=bool(result['complete'] and other['complete'] and same_model and same_inputs and mine==theirs
                        and result.get('functional_digest')==other.get('functional_digest')
                        and result.get('capture_digest')==other.get('capture_digest')))
    out=a.run/'analysis.json'
    data=(json.dumps(result,indent=2)+'\n').encode()
    if out.exists() and out.read_bytes()!=data:
        old=out.read_bytes();archive=out.with_name('analysis-'+hashlib.sha256(old).hexdigest()[:16]+'.json')
        if archive.exists():assert archive.read_bytes()==old
        else:archive.write_bytes(old)
    temp=out.with_name(out.name+'.tmp');temp.write_bytes(data);os.replace(temp,out)
    print(json.dumps({k:result[k] for k in ['path','complete','counts','check_failures'] if k in result}))


if __name__=='__main__':main()
