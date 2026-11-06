#!/usr/bin/env python3
"""Stage read-only next-host diagnostics; never edits/runs the frozen host."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'hg193_combined_hook'))
from prepare import predicates


def assertions(text):
    result=[]
    for match in re.finditer(r'\bassert\s*\(',text):
        start=match.end();depth=1;i=start
        while depth:
            if text[i]=='(':depth+=1
            elif text[i]==')':depth-=1
            i+=1
        result.append(text[start:i-1])
    return result


def split(expr):
    result=[];depth=0;start=0;i=0
    while i<len(expr):
        if expr[i]=='(':depth+=1
        elif expr[i]==')':depth-=1
        elif expr[i:i+2]=='&&'and depth==0:
            result.append(expr[start:i].strip());i+=1;start=i+1
        i+=1
    result.append(expr[start:].strip());return result


def make(parent,out):
    parent,out=parent.resolve(),out.resolve();assert parent!=out
    out.mkdir(parents=True,exist_ok=True)
    macros={}
    adapter=(parent/'include/hg193_sd_pair.svh').read_text()
    for name,value in re.findall(r'^`define\s+(HG_\w+)\s+(.+)$',adapter,re.M):
        for key,target in macros.items():value=value.replace('`'+key,target)
        macros[name]=value
    macros.update(RUNTIME_GX_STORE=macros['HG_STORE'],RUNTIME_GX_SD_ADAPTER=macros['HG_SD'],
        RUNTIME_GX_SD_TRANSPORT_DRAINED='diag_system_drained')
    def expand(expr):
        for key in sorted(macros,key=len,reverse=True):expr=expr.replace('`'+key,macros[key])
        expr=re.sub(r'\bheld\b','diag_held',expr)
        expr=expr.replace('hg193_system_drained','diag_system_drained')
        assert '`'not in expr,expr
        return expr
    groups=predicates()
    # Boundary guards are all pure inputs. Current-register expected values
    # are loaded into existing local buffers only, never into DUT state.
    boundary=adapter.split('task automatic hg193_assert_boundary',1)[1].split('endtask',1)[0]
    for i,expr in enumerate(assertions(boundary)):
        groups['gpu_boundary_'+str(i)]=[expand(term)for term in split(expr)]
    ready=(parent/'include/runtime_import_gx_sd_ready.svh').read_text()
    groups['gpu_pair_drain']=[expand(term)for term in split(assertions(ready)[0])]
    profile=json.loads((parent/'composition.json').read_text())['profile']
    groups['profile60']=[f'dut.{name}==={value}'for name,value in sorted(profile.items())]
    rows=[];lines=['// PROPOSAL: only next required host; no frozen-host modification.',
        'task automatic hg193_all_publication_diagnostics(input string directory);',
        ' bit diag_held,diag_system_drained;',
        ' diag_held=hg193_combined_held;',
        ' diag_system_drained=hg193_combined_transport_drained();',
        ' $readmemh({directory,"/current_regs.hex"},hg193_current);']
    for group,terms in groups.items():
        for index,term in enumerate(terms):
            rows.append(dict(group=group,index=index,expression=term))
            lines.append(f' $display("HG193_ALL_GUARD group={group} index={index} pass=%0b",({term}));')
    lines+=['endtask','']
    text='\n'.join(lines)
    assert '$fatal'not in text and 'force 'not in text and '@('not in text
    (out/'all-publication-diagnostics.svh').write_text(text)
    result=dict(state='SOURCE_ONLY_NOT_COMPILED_OR_INSTALLED',outer_global_clauses=sum(len(v)for v in predicates().values()),
        all_diagnostic_clauses=len(rows),clauses=rows,source_sha256={n:hashlib.sha256((parent/n).read_bytes()).hexdigest()
            for n in ['include/hg193_sd_pair.svh','include/hg193_combined_drain.svh','include/runtime_import_gx_sd_ready.svh']},
        callsite='Immediately after hg193_combined_hold_clocks, before original first assert; existing26CPU clause/raw diagnostics retained. All original asserts still execute unchanged.',
        local_effect='Loads only6 expected current-register words into existing testbench-local buffers. No DUT write, clock edge, request, ownership clear or readiness wait.',
        exclusions='Payload hash/record content and post-publication readback guards stay strict at original locations; not dumped word-by-word. Real accepted/completed CPU owner tuples still missing.',
        guard_enable='Proposal remains0 and uncalled in e383; every existing nonCPU guard unchanged')
    (out/'diagnostics-plan.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:result[k]for k in ['state','outer_global_clauses','all_diagnostic_clauses']},indent=2))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--parent',required=True,type=Path)
    p.add_argument('--out',required=True,type=Path);a=p.parse_args();make(a.parent,a.out)
