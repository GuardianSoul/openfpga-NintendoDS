#!/usr/bin/env python3
"""Read retained traces only; no game/model invocation or timing normalization."""
import bisect
from collections import Counter, defaultdict, deque
import hashlib
import json
from pathlib import Path
import sys

MAIN = Path('/home/user/Git/NDS_Pocket')

def lines(path):
    with path.open('rb') as f:
        h = hashlib.sha256()
        for raw in f:
            h.update(raw)
            if raw[:1] != b'#':
                yield raw.decode().strip().split(',')
    hashes[str(path)] = h.hexdigest()

def stat(hist):
    n = sum(hist.values())
    if not n:
        return {'n': 0}
    ordered = sorted(hist.items())
    result = {'n': n, 'mean': sum(k*v for k,v in ordered)/n,
              'min': ordered[0][0], 'max': ordered[-1][0]}
    for name, numerator in [('p50',50),('p95',95),('p99',99)]:
        target = (n*numerator + 99)//100
        s = 0
        for k,v in ordered:
            s += v
            if s >= target:
                result[name] = k
                break
    return result

def peak_requests(vs,window):
    q=deque();byte_sum=0;peak={}
    for v in vs:
        while q and q[0][2]<=v[2]-window:
            old=q.popleft();byte_sum-=32 if old[5] else 4
        q.append(v);byte_sum+=32 if v[5] else 4
        if byte_sum>peak.get('bytes',0):
            peak=dict(bytes=byte_sum,requests=len(q),first_SYS=q[0][2],last_SYS=v[2],window_SYS=window)
    return peak

def analyze(directory):
    analysis=json.loads((directory/'analysis.json').read_text())
    frames = {}
    done = {}
    requests = []
    for p in lines(directory/'observer.csv'):
        if p[0] == 'FRAME':
            cycle,video,gen,y,abort = map(int,p[1:])
            frames[gen] = dict(cycle=cycle,video_frame=video,start_line=y,abort=abort)
        elif p[0] == 'DONE':
            cycle,video,gen,y,w17,w19,ll20,issue = map(int,p[1:])
            assert (gen,y) not in done
            done[gen,y] = dict(cycle=cycle,y=y,wait17=w17,wait19=w19,ll20=ll20,issue=issue)
        elif p[0] == 'ROW':
            v = list(map(int,p[1:]))
            requests.append(dict(zip(['cycle','video_frame','gen','y','have','partial','render_late',
                'delivery_late','final_rows','started_rows','done','ready','partial_edge','swap','two_d_late'],v)))
    starts = sorted((f['cycle'],g) for g,f in frames.items())
    def generation(c):
        i = bisect.bisect_right(starts,(c,10**9))-1
        return starts[i][1] if i >= 0 else 0
    pergen = defaultdict(lambda: dict(kind=Counter(),completion_SYS=Counter(),wait17_SYS=Counter(),
        wait19_SYS=Counter(),ll20_SYS=Counter(),done_rows=0,port2=defaultdict(Counter),states=Counter(),worst=[]))
    prev = {}
    row_details = []
    for (g,y),r in sorted(done.items()):
        d = pergen[g]
        start = prev.get(g,frames.get(g,{}).get('cycle',r['cycle']))
        interval = r['cycle']-start
        prev[g] = r['cycle']
        d['completion_SYS'][interval] += 1
        for k in ['wait17','wait19','ll20']:
            d[k+'_SYS'][r[k]] += 1
        d['done_rows'] += 1
        r = dict(r,gen=g,interval_SYS=interval)
        row_details.append(r)
        d['worst'] = sorted(d['worst']+[r],key=lambda x:x['interval_SYS'],reverse=True)[:5]
    for r in requests:
        d = pergen[r['gen']]
        k = ('partial' if r['partial'] else 'full') if r['have'] else 'render-late' if r['render_late'] else 'delivery-late' if r['delivery_late'] else 'other'
        d['kind'][k] += 1
        if r['render_late']:
            z = done.get((r['gen'],r['y']))
            if z:
                d.setdefault('late_completion_after_request_SYS',Counter())[z['cycle']-r['cycle']] += 1
        if k=='render-late' and len(d.setdefault('first_late_rows',[]))<3:
            z=done.get((r['gen'],r['y']))
            d['first_late_rows'].append(dict(r,actual_DONE_SYS=z['cycle'] if z else None))
    # Match every physical event in FIFO order. Prefix can be one crossing
    # already offered before the observer starts, never an internal mismatch.
    vs,mos,mts = [],[],[]
    event_counts = Counter()
    for p in lines(directory/'observer.csv.waits.csv'):
        event_counts[p[0]] += 1
        if p[0] == 'V':
            vs.append((int(p[4],16),int(p[2]),int(p[1]),int(p[3]),int(p[5]),int(p[6])))
            assert vs[-1][2] <= analysis['totals']['cycles'], 'V timestamp is not SYS cycle'
        elif p[0] == 'MO':
            mos.append((int(p[2],16),int(p[1]),*map(int,p[3:])))
        elif p[0] == 'MT':
            mts.append((int(p[2],16),int(p[1])))
    def align(a,b):
        candidates=[]
        for off in [-1,0,1]:
            ai,bi=max(off,0),max(-off,0)
            n=min(len(a)-ai,len(b)-bi)
            if n and all(a[ai+k][0]==b[bi+k][0] for k in range(n)):
                candidates.append((n,ai,bi))
        assert candidates, (directory,len(a),len(b),'FIFO address mismatch')
        return max(candidates)
    n,mi,ti=align(mos,mts)
    nv,vi,mvi=align(vs,mos)
    mov={mvi+k:vs[vi+k] for k in range(nv)}
    all_latency=defaultdict(Counter)
    bank=Counter()
    offer_snapshot=Counter();by_MCstate=defaultdict(Counter)
    for k in range(n):
        m=mos[mi+k];t=mts[ti+k]
        assert t[1]>=m[1]
        latency=t[1]-m[1]
        all_latency['MO_MT_ps'][latency]+=1
        bank[(m[0]>>21)&3]+=1
        offer_snapshot[','.join(map(str,m[2:]))]+=1
        by_MCstate[m[4]][latency]+=1
        if mi+k in mov:
            v=mov[mi+k]
            assert 0<=m[1]-v[1]<=5000, 'V/MO phase or address association'
            g=generation(v[2]);d=pergen[g]
            for name,value in [('MO_MT_ps',latency),('V_MO_ps',m[1]-v[1]),('V_MT_ps',t[1]-v[1])]:
                d['port2'][name][value]+=1
                if name!='MO_MT_ps':all_latency[name][value]+=1
            d['states'][f'st{v[3]}_we{v[4]}_blk{v[5]}']+=1
            d.setdefault('MO_snapshot',Counter())[','.join(map(str,m[2:]))]+=1
    result={}
    for g,d in sorted(pergen.items()):
        out={k:v for k,v in d.items() if k not in ['port2','completion_SYS','wait17_SYS','wait19_SYS','ll20_SYS','late_completion_after_request_SYS']}
        out['frame']=frames.get(g)
        out['port2']={k:stat(v) for k,v in d['port2'].items()}
        for k in ['completion_SYS','wait17_SYS','wait19_SYS','ll20_SYS','late_completion_after_request_SYS']:
            if k in d:out[k]=stat(d[k])
        result[g]=out
    kinds=Counter()
    for d in pergen.values():kinds.update(d['kind'])
    assert all(kinds[k]==v for k,v in analysis['counts'].items()), (kinds,analysis['counts'])
    return dict(path=str(directory),counts=analysis['counts'],totals=analysis['totals'],generations=result,
        port2=dict(physical_latency={k:stat(v) for k,v in all_latency.items()},bank=bank,
            offer_snapshot_gv_g_mcst_refowed=offer_snapshot,V=len(vs),MO=len(mos),MT=len(mts),
            latency_ps_by_MCstate_at_offer={k:stat(v) for k,v in by_MCstate.items()},
            peak_offered_bytes=[peak_requests(vs,w) for w in [1400,4260]],
            MO_MT_alignment=[mi,ti,n],V_MO_alignment=[vi,mvi,nv]),events=event_counts,
        row_details=row_details)

hashes={}
def main():
    out=Path(sys.argv[1]);assert out.is_dir()
    scenes=[('e63-'+s,MAIN/'build/rc053-elastic-ring-games'/(s+'-final-elastic-banked-ring-capture-observe')) for s in ['race','battle','title']]
    scenes += [('parent-race',MAIN/'build/rc053-texture-games/race-final-texpool-capture-observe')]
    results={}
    for name,d in scenes:
        r=analyze(d)
        (out/(name+'-rows.json')).write_text(json.dumps(r.pop('row_details'),separators=(',',':'))+'\n')
        results[name]=r
        print(name,r['counts'],r['port2']['physical_latency'],flush=True)
    (out/'trace-screen.json').write_text(json.dumps(dict(PASS=True,limitations=[
        'Different CPU/ring sources and import releases; generations are not matched game content.',
        'MO MC/grant snapshot does not identify the exclusive active competing owner.',
        'wait17/19/ll20 counters index frontend geometry y; DONE indexes final-pass output y. Their intervals differ and waits can exceed consecutive-DONE gaps. Do not subtract or claim exclusive cost.',
        'Physical latency ends at controller acceptance, not returned data.',
        'Absolute recorded ps and SYS counters; no phase/clock/cadence correction applied.'
        ],input_sha256=hashes,scenes=results),indent=2)+'\n')
if __name__=='__main__':main()
