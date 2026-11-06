#!/usr/bin/env python3
"""Raw native taps only: source/ROI/integrity checks, no invented ownership."""
from pathlib import Path
from collections import Counter
import argparse,csv,gzip,hashlib,json,re
PLAN=Path(__file__).with_name("ldm53_observer_plan.json")
SV=Path("sim/pocket_ds/ldm53_observer.sv")
MASK=(1<<64)-1
OFFSET=1469598103934665603
PRIME=1099511628211
EV=dict(BEGIN_CALL=1,END_CALL=2,PIPE=3,DATA=4,PERMIT=5,DP_CAPTURE=6,BUS=7,
        GRANT=8,RAW=9,FAB_ACK=10,CPU_ACK=11,WB=12,RF=13,RETIRE=14,
        HOLD=15,WORK=16,ISSUE=17,CONFIG=18,RESET=19,FINISH=255)
LANE={1:1,2:1,3:1,4:1,5:2,6:2,7:2,8:3,9:3,10:3,11:2,12:2,
      13:1,14:1,15:1,16:3,17:1,18:0,19:0,255:0}
NO_PC={3,7,8,9,10,11,15,16,18,19,255}
def require(ok,why):
    if not ok:raise ValueError(why)
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def fold(h,values):
    for v in values:h=((h^v)*PRIME)&MASK
    return h
def roi_file(path):
    rows=Path(path).read_text().splitlines()
    require(len(rows)==742 and all(r in ("0","1")for r in rows),"FROZEN_ROI_742_BITS")
    return list(map(int,rows))
def schedule(plan):
    for k,f in enumerate(plan["forms"]):
        for off in range(0,16 if f["words"]else 4,4):
            for loops in (16,64):
                for rep in range(7):
                    code=plan["anchor_pc"]if k==3 and rep<6 else plan["copy_pc"]
                    ops=[int(x,16)for x in f["opcodes"]]
                    if rep==6:ops[-2:]=[0xe59f1008,0xe88103fc,0xe8bd03f0,0xe12fff1e,plan["snapshot"]]
                    ret=code+4*(max(i for i,w in enumerate(ops)if w==0xe12fff1e))
                    yield dict(form=k,name=f["name"],words=f["words"],fixed=f["fixed"],
                        base=plan["main_data"]+off+(512 if f["fixed"]else 0),loops=loops,rep=rep,
                        code=code,last_pc=ret,opcodes=ops,expected=loops*16*f["words"])
class Verifier:
    def __init__(self,calls,roi,main=0x0202c5a0):
        self.calls,self.roi,self.main=calls,roi,main
        self.seq=self.tick=self.begun=self.ended=0
        self.digest=OFFSET;self.active=None;self.pipe=None;self.done=False
        self.config=False;self.counts=Counter()
    def take(self,r):
        require(len(r)==13 and all(0<=x<=MASK for x in r),"SCHEMA")
        seq,tick,kind,lane,pc,*v=r
        require(not self.done and seq==self.seq+1,"DROPPED_OR_REORDERED_RECORD")
        require(tick>=self.tick,"CLOCK_REWIND")
        require(kind in LANE and lane==LANE[kind],"MISOWNED_SOURCE_ENDPOINT")
        if kind in NO_PC:require(pc==0,"UNQUALIFIED_ENDPOINT_PC")
        if kind==EV["CONFIG"]:
            require(not self.config and seq==1 and v[:3]==[sum(self.roi),fold(OFFSET,self.roi),len(self.calls)],
                    "FROZEN_ROI_CONFIG")
            self.config=True
        elif kind==EV["RESET"]:require(not self.begun,"RESET_MEASURED_WINDOW")
        elif kind==EV["BEGIN_CALL"]:
            require(self.config and self.active is None and v[0]==self.begun and
                    self.begun<len(self.calls),"CALL_ORDER")
            q=self.calls[self.begun];detail=self.roi[self.begun]
            require(pc==q["code"] and v[1:7]==[0xe92d03f0,q["expected"],detail,q["last_pc"],q["base"],q["form"]],
                    "ACTUAL_CALL_CONTEXT")
            self.active=dict(spec=q,index=self.begun,detail=detail,words=0,hash=OFFSET,start=tick)
            self.begun+=1
        elif kind==EV["END_CALL"]:
            require(self.active is not None,"UNBOUND_END")
            a=self.active;q=a["spec"]
            require(pc==q["last_pc"]and v[0]==a["index"]and v[1]==v[2]==q["expected"]and
                    v[4:]==[a["detail"],q["form"],a["start"],tick],"CALL_COMPLETENESS")
            if a["detail"]:require(a["words"]==q["expected"]and a["hash"]==v[3],"DETAILED_CALL_COUNT_HASH")
            self.active=None;self.ended+=1
        elif kind==EV["FINISH"]:
            require(v[0]==self.seq and v[1]==self.digest,"FOOTER_DIGEST")
            require(v[2]==v[3]==self.begun==self.ended==len(self.calls)and not v[4]and self.active is None,
                    "INCOMPLETE_742_CALL_WINDOW")
            self.done=True
        else:
            require(self.active is not None and self.active["detail"],"DETAIL_OUTSIDE_FROZEN_ROI")
            if kind==EV["PIPE"]:self.pipe=(tick,v)
            elif kind in (4,5,6,12,13,14):
                require(self.pipe is not None and self.pipe[0]==tick,"MISSING_NATIVE_PIPE_SAMPLE")
                p=self.pipe[1];stage=2 if kind==4 else 3 if kind in (5,6,12)else 4
                require(pc==p[stage]and p[5]&(1<<stage),"MISOWNED_NATIVE_STAGE_PC")
            elif kind==EV["ISSUE"]:
                q=self.active["spec"];offset=pc-q["code"]
                if offset>=0 and offset%4==0 and offset//4<len(q["opcodes"]):
                    require(v[0]==q["opcodes"][offset//4],"ACTUAL_BODY_OPCODE")
                require(v[6:]==[0,0],"ARM9_ARM_CONTEXT")
            if kind==EV["CPU_ACK"]and not v[4]and self.main<=v[0]<self.main+98304:
                a=self.active;q=a["spec"];span=q["words"]if q["fixed"]else 16*q["words"]
                require(span and v[0]==q["base"]+(a["words"]%span)*4,"CAPTURED_CALL_DATA_ORDER")
                a["words"]+=1;a["hash"]=fold(a["hash"],[v[0],v[2],v[1]])
        self.digest=fold(self.digest,r);self.seq,self.tick=seq,tick;self.counts[kind]+=1
    def result(self):
        require(self.done,"MISSING_FOOTER")
        return dict(status="PASS_RAW_CAPTURE_CONTRACT_ONLY",records=self.seq,calls=self.ended,
            detailed_calls=sum(self.roi),events=dict(self.counts),
            ownership="UNQUALIFIED dynamic dp/fabric/end instruction association; native stage-PC checks only",
            timing="No DS timing acceptance; all53 original result rows remain required")
def parse(stream):
    require(stream.readline().strip()=="#LDM53RAW,1","HEADER")
    for row in csv.reader(stream):
        require(len(row)==13,"SCHEMA")
        yield[int(x,10 if i<4 else 16)for i,x in enumerate(row)]
def issue_word_check(core,observer):
    # A specific declaration/dataflow check, not a general SV scope parser.
    require(re.search(r"(?m)^  logic\s+\[31:0\]\s+c_ins,\s*c_tgt,\s*c_pc\s*;",core),
            "ISSUE_WORD_MODULE_DECLARATION")
    for pattern in (r"\bassign\s+c_ins\s*=\s*ib_d\.ins\s*;",
                    r"\bassign\s+c_pc\s*=\s*ib_d\.pc\s*;",
                    r"\bins\s*=\s*c_ins\s*;",
                    r"\bu\.pc\s*=\s*c_pc\s*;",
                    r"\bu\.valid\s*=\s*have\s*;"):
        require(re.search(pattern,core),"ISSUE_WORD_PC_SAME_D_SOURCE")
    require(not re.search(r"\x60L53C\.ins\b",observer),"BLOCK_LOCAL_INS_IS_NOT_A_MODULE_TAP")
    require(len(re.findall(r"\x60L53C\.c_ins\b",observer))==3,"THREE_NATIVE_D_WORD_TAPS")
    return dict(word="u_core.c_ins",pc="u_core.u.pc",
        source="c_ins=ib_d.ins; c_pc=ib_d.pc; decode local ins=c_ins; u.pc=c_pc",
        acceptance="pre-edge ce && u.valid; u.valid=have; entry also fresh",
        scope="ARM LDM53 issue word; no retirement/other-stage substitution")
def source_check(root,plan):
    guards={}
    for name,g in plan["source_blocks"].items():
        s=(root/name.split(":",1)[0]).read_text();a=s.index(g["start_marker"])
        b=s.index(g["end_marker_exclusive"],a+len(g["start_marker"]))
        h=hashlib.sha256(s[a:b].encode()).hexdigest()
        require(h==g["fragment_sha256"],"SOURCE_GUARD_REVIEW_REQUIRED:"+name);guards[name]=h
    s=(root/SV).read_text();code=re.sub(r"//.*","",s)
    require(not re.search(r"\b(force|release|deposit)\b",code),"DUT_DRIVE")
    require(not re.search(r"\x60L53[ACDMF][\w.\[\]:]*\s*(?:<=|=(?!=))",code),"DUT_LHS")
    require('if(enabled)begin'in s and '$value$plusargs("ldm53_observe=%s",path)'in s,"INACTIVE_GUARD")
    require("ldm_answers"not in s and "128"not in s,"GLOBAL_ACK_CAP")
    issue_word=issue_word_check((root/"rtl/arm/arm_core.sv").read_text(),s)
    # Other tap-name checks are lexical only, NOT SV scope/elaboration checks.
    paths={"A":"rtl/arm/arm_cpu.sv","C":"rtl/arm/arm_core.sv",
           "M":"rtl/arm/arm9_mem.sv","F":"rtl/ds/nds_fabric.sv","D":"rtl/pocket/core_top_ds.sv"}
    for alias,tap in re.findall(r"\x60L53([ACMFD])\.([A-Za-z_]\w*)",code):
        require(re.search(r"\b"+re.escape(tap)+r"\b",(root/paths[alias]).read_text())is not None,
                "TAP_NOT_IN_ACTUAL_SOURCE:"+alias+"."+tap)
    return dict(status="RAW_SOURCE_READY_UNELABORATED",source_blocks=guards,observer_sha256=sha(root/SV),
        verifier_sha256=sha(__file__),plan_sha256=sha(PLAN),include=str(SV),issue_word=issue_word,
        not_qualified=["elaboration","default-inactive producer state/input/clock identity",
                       "enabled real capture","dynamic instruction/uop ownership","DS timing"])
def main():
    ap=argparse.ArgumentParser(__doc__);sub=ap.add_subparsers(dest="command",required=True)
    p=sub.add_parser("source-check");p.add_argument("--root",type=Path,default=Path(__file__).parents[2])
    p.add_argument("--out",type=Path,required=True)
    p=sub.add_parser("verify");p.add_argument("--trace",type=Path,required=True)
    p.add_argument("--binding",type=Path,required=True);p.add_argument("--roi",type=Path,required=True)
    p.add_argument("--out",type=Path,required=True);args=ap.parse_args()
    plan=json.loads(PLAN.read_text())
    if args.command=="source-check":result=source_check(args.root,plan)
    else:
        b=json.loads(args.binding.read_text())
        require(b["rom_sha256"]==plan["ROM_sha256"]and b["observer_sha256"]==sha(Path(__file__).parents[2]/SV),
                "ACTUAL_ROM_OBSERVER_BINDING")
        require(b["compiled_observer_sha256"]==b["observer_sha256"]and
                b["roi_sha256"]==sha(args.roi)and b["profile"]==plan["profile"],"COMPILED_ROI_PROFILE_BINDING")
        require(re.fullmatch("[0-9a-f]{64}",b["model_sha256"])is not None,"MODEL_BINDING")
        require(re.fullmatch("[0-9a-f]{40}",b["source"])is not None,"SOURCE_BINDING")
        require(b["source_check"]["status"]=="RAW_SOURCE_READY_UNELABORATED"and
                b["source_check"]["source_blocks"]=={k:v["fragment_sha256"]for k,v in plan["source_blocks"].items()},
                "NINE_SOURCE_GUARDS")
        v=Verifier(list(schedule(plan)),roi_file(args.roi))
        with(gzip.open if args.trace.suffix==".gz"else open)(args.trace,"rt")as f:
            for row in parse(f):v.take(row)
        result={**v.result(),"trace_sha256":sha(args.trace),"binding_sha256":sha(args.binding)}
    args.out.parent.mkdir(parents=True,exist_ok=True);args.out.write_text(json.dumps(result,indent=2)+"\n")
    print(result["status"])
if __name__=="__main__":main()
