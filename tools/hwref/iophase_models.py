#!/usr/bin/env python3
"""Offline proposal/checker only; no ROM, emulator, staging or hardware action."""
import argparse,csv,json
from pathlib import Path

CASES=[dict(case=i,prefix=p,gap=g)for i,(g,p)in enumerate([(0,0),(0,1),(1,0),(1,1)])]
REPS=16
def predict(delta,phase):
    """Bounded aliases:8 FCLK/read,1 FCLK/NOP,2 FCLK/timer tick.

    delta is write-commit minus read-sample offset within an instruction.
    Distinct internal implementations with the same delta remain aliases.
    """
    rows=[]
    for c in CASES:
        p=(phase+c['prefix'])%2
        calibration=(p+9)//2
        p1=(p+9)%2
        stop=(p1+8+c['gap']+delta)//2
        rows.append(dict(**c,read_read_ticks=calibration,read_stop_ticks=stop))
    return rows
def plan():
    models={f'event_delta{d}_phase{p}':predict(d,p)for d in [0,1]for p in [0,1]}
    vectors={k:tuple((r['read_read_ticks'],r['read_stop_ticks'])for r in v)for k,v in models.items()}
    assert len(set(vectors.values()))==4
    # Incorrectly merging the read/write event offsets destroys the proposed
    # discrimination. This is an analytic-checker mutation, not an RTL fault.
    mutated={f'event_delta{d}_phase{p}':tuple((r['read_read_ticks'],r['read_stop_ticks'])for r in predict(0,p))for d in [0,1]for p in [0,1]}
    assert len(set(mutated.values()))==2
    return dict(status='OFFLINE PROPOSAL ONLY; no producer/ROM/software qualification/staging',cases=CASES,repetitions=REPS,rows=64,
      models=models,analytic_mutation_caught=dict(kind='force write/read event delta equal',unique_vectors_before=4,after=2),
      scope='Observable timer differences, not inferred internal stage identity; all aliases with equal event delta stay equivalent',
      unknowns=['Real timer-port read interval versus the existing DISPSTAT interval','phase locking may reject all4 hypotheses',
                'bit23/sound/GX/serial and all other buses are out of scope'])
def check(path):
    rows=list(csv.DictReader(path.open()));expected={(c['case'],r)for c in CASES for r in range(REPS)}
    assert len(rows)==64 and {(int(r['case']),int(r['rep']))for r in rows}==expected,'incomplete/duplicate rows'
    values={c['case']:set()for c in CASES};observations=[]
    for r in rows:
        c=CASES[int(r['case'])];assert int(r['prefix'])==c['prefix']and int(r['gap'])==c['gap'],'descriptor differs'
        x=[int(r['r'+str(i)],0)for i in range(4)];assert all(0<=v<=65535 for v in x),'raw16 range'
        assert int(r['irq_masked'])==1 and int(r['timeout'])==0,'producer did not complete protected window'
        # Unexpected stop/control/counter results remain observations, not a
        # reason to discard complete hardware captures or alter the oracle.
        dcal=(x[1]-x[0])&65535;dstop=(x[2]-x[1])&65535
        values[c['case']].add((dcal,dstop))
        observations.append(dict(case=c['case'],rep=int(r['rep']),read_read_ticks=dcal,read_stop_ticks=dstop,
          stopped_value_stable=x[2]==x[3],control_before=int(r['control_before'],0),control_after=int(r['control_after'],0)))
    models=plan()['models'];compatible=[]
    for name,predictions in models.items():
        if all(values[p['case']]=={(p['read_read_ticks'],p['read_stop_ticks'])}for p in predictions):compatible.append(name)
    return dict(output_complete=True,rows=64,observations=observations,compatible_finite_models=compatible,
                all_models_rejected=not compatible,hardware_rule_adopted=False,
                scope='Capture completeness and finite predictions only; external ROM/ELF/MPU/source provenance still required')
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--csv',type=Path);a=p.parse_args()
    print(json.dumps(check(a.csv)if a.csv else plan(),indent=2)+'\n',end='')
