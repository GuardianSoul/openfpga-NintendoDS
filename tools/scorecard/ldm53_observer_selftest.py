#!/usr/bin/env python3
"""HOST CONTRACT controls only; not SV elaboration/default-off/capture proof."""
from pathlib import Path
from copy import deepcopy
import argparse,io,json,re
import ldm53_observer as o
def encoded(rows):
    rows=deepcopy(rows);h=o.OFFSET
    for n,r in enumerate(rows,1):r[0]=n;h=o.fold(h,r)
    rows.append([len(rows)+1,rows[-1][1],255,0,0,len(rows),h,1,1,0,0,0,0])
    return "#LDM53RAW,1\n"+"\n".join(",".join(str(v)if i<4 else f"{v:x}"for i,v in enumerate(r))for r in rows)+"\n"
def fixture():
    pc,main=0x01ff8020,0x0202c5a0
    q=dict(code=pc,last_pc=pc+8,form=0,expected=1,words=1,fixed=True,base=main,
           opcodes=[0xe92d03f0,0xe8bc0004,0xe12fff1e])
    rows=[]
    def add(kind,tick,lane,owner=0,*v):
        rows.append([0,tick,o.EV[kind],lane,owner]+list(v)+[0]*(8-len(v)))
    def pipe(tick,xpc=pc+4):
        add("PIPE",tick,1,0,pc,pc+4,pc+4,pc+4,xpc,60,0,0)
    add("CONFIG",0,0,0,1,o.fold(o.OFFSET,[1]),1)
    add("BEGIN_CALL",1,1,pc,0,0xe92d03f0,1,1,pc+8,main,0,0x13)
    pipe(2);add("DATA",2,1,pc+4,main,0x61)
    pipe(3);add("PERMIT",3,2,pc+4,main,0x61)
    add("DP_CAPTURE",3,2,pc+4,main,0x61)
    add("GRANT",4,3,0,main,0x61)
    add("RAW",5,3,0,main,0x61,0x1234,1,1,4)
    add("FAB_ACK",8,3,0,main,0x61,0x1234,1,0)
    add("CPU_ACK",8,2,0,main,0x61,0x1234,1,0)
    pipe(9);add("WB",9,2,pc+4,1)
    pipe(10);add("RF",10,1,pc+4,2,0x1234)
    pipe(11,pc+8);add("RETIRE",11,1,pc+8)
    h=o.fold(o.OFFSET,[main,0x1234,0x61])
    add("END_CALL",11,1,pc+8,0,1,1,h,1,0,1,11)
    return q,rows
def verify(q,text):
    v=o.Verifier([q],[1])
    for row in o.parse(io.StringIO(text)):v.take(row)
    return v.result()
def run():
    q,rows=fixture();verify(q,encoded(rows));faults={}
    bad=encoded(rows).splitlines();raw=next(i for i,l in enumerate(bad)if i and l.split(",")[2]=="9")
    del bad[raw]
    cases={"dropped_raw_original_sequence":"\n".join(bad)+"\n"}
    bad=deepcopy(rows);next(r for r in bad if r[2]==5)[4]+=4
    cases["misowned_permission_PC_resealed_footer"]=encoded(bad)
    bad=deepcopy(rows);next(r for r in bad if r[2]==9)[4]=q["code"]+4
    cases["last_retired_PC_injected_on_raw_resealed_footer"]=encoded(bad)
    bad=deepcopy(rows);next(r for r in bad if r[2]==2)[6]=0
    cases["wrong_complete_call_count"]=encoded(bad)
    cases["missing_footer"]="\n".join(encoded(rows).splitlines()[:-1])+"\n"
    for k,t in cases.items():
        try:verify(q,t)
        except ValueError as e:faults[k]=str(e)
        else:raise AssertionError("fault escaped:"+k)
    plan=json.loads(o.PLAN.read_text());calls=list(o.schedule(plan))
    assert len(calls)==742 and sum(x["rep"]<6 for x in calls)==636
    assert sum(x["rep"]==6 for x in calls)==106
    roi=o.roi_file(Path(__file__).with_name("ldm53_roi_first_timed.hex"))
    assert sum(roi)==106 and sum(c["expected"]for c,r in zip(calls,roi)if r)==358400
    assert sum(c["expected"]for c in calls)==2508800
    # Check source helper return targets against ACTUAL retained BX opcode.
    sv=(Path(__file__).parents[2]/o.SV).read_text()
    assert "bytes(n)-4+(n%7==6?8:0)"in sv
    for n,c in enumerate(calls):
        k=n//56 if n//7<104 else 13
        context=(n//7)%8 if k<13 else n//7-104
        f=plan["forms"][k]
        assert c["expected"]==(64 if context%2 else 16)*16*f["words"]
        assert c["last_pc"]==c["code"]+f["bytes"]-4+(8 if n%7==6 else 0)
        assert c["opcodes"][(c["last_pc"]-c["code"])//4]==0xe12fff1e
    ids={k:int(v)for k,v in re.findall(r"\b([A-Z_]+)=(\d+)",sv)}
    assert all(ids[k]==v for k,v in o.EV.items())
    core=(Path(__file__).parents[2]/"rtl/arm/arm_core.sv").read_text()
    o.issue_word_check(core,sv)
    for name,candidate_core,candidate_sv in [
        ("block_local_ins_tap",core,sv.replace(".c_ins",".ins")),
        ("issue_word_from_other_PC",core.replace("assign c_pc      = ib_d.pc;",
                                               "assign c_pc      = dbg_pc;"),sv)]:
        try:o.issue_word_check(candidate_core,candidate_sv)
        except ValueError as exc:faults[name]=str(exc)
        else:raise AssertionError("issue source fault escaped:"+name)
    return dict(status="PASS_RAW_HOST_CONTRACT_ONLY",faults=faults,calls=742,
        timer_calls=636,signature_calls=106,return_PC_checks=742,detailed_candidate_calls=106,
        detailed_body_words=358400,all_body_words=2508800,
        scope="Generated raw event fixture; native same-edge stage-PC checks only. No dynamic instruction ownership or SV execution qualification.")
if __name__=="__main__":
    ap=argparse.ArgumentParser(__doc__);ap.add_argument("--out",type=Path,required=True);a=ap.parse_args()
    r=run();a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(r,indent=2)+"\n");print(r["status"])
