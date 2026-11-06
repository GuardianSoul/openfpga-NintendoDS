#!/usr/bin/env python3
"""Bound the actual caller's writers and preserve imported state, no simulation."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True)
p.add_argument('--before',default='362fea1dc1fcaee361977f06fd12826d45d03699');a=p.parse_args()
out=a.out.resolve();out.mkdir(parents=True,exist_ok=True)
H=lambda b:hashlib.sha256(b).hexdigest()
paths=['rtl/gpu3d/gpu3d_gxu_pkg.sv','rtl/gpu3d/gpu3d_gxrom_ux.sv','rtl/gpu3d/gpu3d_gxeng.sv','rtl/gpu3d/gpu3d_gxlight.sv','rtl/gpu3d/gpu3d_gxvfin.sv','sim/ds/runtime_gx_context.py','sim/pocket_ds/runtime_import_gx_context.svh']
src={n:(ROOT/n).read_bytes()for n in paths}
pkg=src[paths[0]].decode();rom=src[paths[1]].decode();eng=src[paths[2]].decode();light=src[paths[3]].decode()
assert 'localparam int C_LBUSY = 16;' in pkg
before={n:subprocess.check_output(['git','show',a.before+':'+n],cwd=ROOT)for n in paths}
assert eng.replace('.SHARED5(MAT_PAR), ','').encode()==before[paths[2]]
for n in [paths[0],paths[1],paths[4],paths[5],paths[6]]:assert src[n]==before[n],n
prefix=lambda s:s[s.index('module gpu3d_gxlightp #('):].split('    // ---- the pipeline',1)[0]
prefix_new=re.sub(r'^    parameter bit SHARED5 =.*\n','',prefix(light),flags=re.M)
prefix_new=prefix_new.replace("    parameter bit NOWR = 1'b0,\n", "    parameter bit NOWR = 1'b0\n")
assert prefix_new==prefix(before[paths[3]].decode())
param_names=lambda s:re.findall(r'\b([A-Za-z_]\w*)\s*=',prefix(s).split(') (',1)[0])
assert param_names(light)==param_names(before[paths[3]].decode())+['SHARED5']
old_helper=before[paths[3]].decode().split('module gpu3d_gxlight_products (',1)[1].split('endmodule',1)[0]
assert old_helper==light.split('module gpu3d_gxlight_products (',1)[1].split('endmodule',1)[0]
# Imported coefficients, controls, four complete tables, declaration dimensions,
# snoop/packed precedence and sequencer remain in exactly the original scope.
imported=sorted(set(re.findall(r'`RUNTIME_GEOMETRY\.u_eng\.g_lup\.u_light\.([A-Za-z_]\w*(?:\[\d+\])*(?:\.[A-Za-z_]\w*(?:\[\d+\])*)*)\s*=',src[paths[6]].decode())))
assert len(imported)==618
roots=sorted({v.split('[',1)[0].split('.',1)[0]for v in imported})
assert roots==['g_sh','light_color','lmask','lt','mamb_cache','mdif_cache','memi','mspe_cache','ut','vec']
safe_mask=int(re.search(r"LU_SAFE = 64'h([0-9A-F]+)",pkg)[1],16)
def hidx(c):
    if 0x10<=c<=0x1c:return c-0x10+1
    if 0x20<=c<=0x2b:return c-0x20+14
    if 0x30<=c<=0x34:return c-0x30+26
    if c in [0x40,0x41]:return c-0x40+31
    if 0x50<=c<=0x50:return 33
    if 0x60<=c<=0x60:return 34
    if 0x70<=c<=0x72:return c-0x70+35
    return 0
safe_cmd=[0]+list(range(0x22,0x2c))+[0x41]
assert safe_mask==sum(1<<hidx(c)for c in safe_cmd)
for c in list(range(0x10,0x1d))+[0x30,0x31,0x32,0x33,0x34]:assert not safe_mask>>hidx(c)&1
assert '!(LUNIT && lu_busy && !LU_SAFE[e_hidx] && !lu_pre)'in eng
assert 'wire pop     = a_nx == NX_DISP && ev;'in eng
assert "if (pop) lu_pre <= 1'b0;"in eng and "else if (lu_early || lu_conf) lu_pre <= 1'b1;"in eng
assert 'lu_hn    = ev_q && e_hidx == LU_HNORMAL' in eng
assert 'lu_conf  = lu_chk && lu_hn && e_data[29:0] == lu_nr;'in eng
assert "mat_m <= !rst && mat_o;"in eng and "mat_o <= !rst && pu_mat;"in eng
assert 'we_m <= we_o;'in eng and 'we_o <= i_we;'in eng
assert "if (cnt == 3'd2) begin st <= S_RUN;"in light
assert "gb = 11'h200 + {5'd0, g, 4'd0};"in eng
assert "if (PU && ff_vtx) xr1 <= pu_cur;"in eng
assert "if (pu_step && pu_done) begin xr1 <= pu_x1; xr2 <= pu_x2; xr3 <= pu_x3; end"in eng
words={int(i):int(v,16)for i,v in re.findall(r"ra\[(\d+)\] = 70'h([a-f0-9]+);",rom)}
assert len(words)==2048
vadv=sorted(pc for pc,v in words.items()if(v>>59&7)==5 and(v>>62&2))
assert vadv==[778,786]
# Exhaust the FROZEN image, not assembler output. During actual RUN/held FIN,
# lu_cready=0 and C_LBUSY is true; other branch conditions are unconstrained.
# Every possible CALL/RET stack is followed; DISP's no-entry/read target is
# included. New safe dispatch, already-owned NORMAL and fast SV1 are roots.
seeds=sorted({i for i in range(64)if safe_mask>>i&1}|{15,775,778,786})
def reach(w):
    todo=[(i,())for i in seeds];seen=set();pcs=set()
    while todo:
        pc,stack=todo.pop()
        if(pc,stack)in seen:continue
        seen.add((pc,stack));pcs.add(pc);v=w[pc];nx=v&7;t=v>>3&2047;c=v>>14&31
        if nx==6:dest=[t]
        elif nx==4:
            assert len(stack)<8;todo.append((t,stack+(pc+1,)));continue
        elif nx==5:
            if stack:todo.append((stack[-1],stack[:-1]))
            continue
        elif nx==1:dest=[t]
        elif nx in [2,3]:dest=([t]if nx==2 else[pc+1])if c==16 else[t,pc+1]
        elif nx==7:dest=[t,pc+1]
        else:dest=[pc+1]
        todo.extend((d%2048,stack)for d in dest)
    return seen,pcs
seen,pcs=reach(words)
arith=set(range(0x20,0x30))|set(range(0x100,0x140))|set(range(0x180,0x200))|{0xe1}|set(range(0x158,0x164))
direct=[];indexed=[]
for pc in sorted(pcs):
    w=words[pc]
    if not w>>58&1:continue
    wx=w>>56&3;wa=w>>45&2047
    if wx:assert wx in [1,2]and wa<=15;indexed.append(dict(PC=pc,index=wx,offset=wa))
    else:assert wa not in arith;direct.append(dict(PC=pc,address=wa))
# Existing legal group ownership puts X1/X2 at aligned0x200..0x3f0 on
# these indexed writes. Check all32groups×all indexed offsets, not one scene.
group_addresses={g+r['offset']for g in range(0x200,0x400,16)for r in indexed}
assert not arith.intersection(group_addresses)
# Collection overrides the normal destination to PARAM + six-bit pi.
assert not arith.intersection(range(0x80,0xc0))
# Other RF writers: owned group words and fixed metadata/CURCOL. CATTR is
# intentionally allowed: lm was already captured and lmask may change.
metadata={0xd1,0xda,0xd3,0xe3,0xe5,0xe6,0xe7,0xe9,0xeb,0xec,0xed,0xee}|set(range(0x171,0x17b))|set(range(0x14b,0x14e))
assert not arith.intersection(metadata|set(range(0x200,0x400)))
mut=copy.copy(words);fault=next(r['PC']for r in direct if r['address']==0x14e)
mut[fault]=(mut[fault]&~(2047<<45))|(0x20<<45)
_,mutpcs=reach(mut)
assert any((mut[x]>>58&1) and (mut[x]>>56&3)==0 and (mut[x]>>45&2047) in arith for x in mutpcs)
result=dict(before=a.before,source_sha256={n:H(b)for n,b in src.items()},
    ABI=dict(imported_assignments=len(imported),paths=imported,roots=roots,prefix_exact=True,ports_and_root_config='Original unit ports/default SHARED5=0 and all existing root parameter defaults unchanged; engine adds private opt-in only. These checks preserve import names/contents, not a new whole-runtime restoration qualification.'),
    writer_CFG=dict(rom='actual frozen ux2048x70',safe_commands=safe_cmd,owned_normal=15,fast_vertex_entry=775,VADV=vadv,states=len(seen),PCs=len(pcs),direct_writes=direct,indexed_writes=indexed,collect_destinations=[0x80,0xbf],other_writer_metadata=sorted(metadata),arithmetic_destinations=sorted(arith),direct_unsafe_writes=0,group_overlap=0,
       indexed_scope='Uses retained legal group ownership/alignment (slots/clip pool0x200..0x3f0), not arbitrary corrupt X registers. Actual trace snapshot checks arithmetic mirrors directly; it is not an independent arbitrary-X group-range proof. No universal arbitrary-import-state theorem.',
       control_scope='C_LBUSY true in actual MAT_PAR/NOWR1 RUN and held FIN: lu_cready cleared at start; first unheld publication frees unit at same SYS edge that sets lu_cready. All other predicates explored both ways. Returns use exact call stacks; no new unsafe command can dispatch while busy except the already-owned NORMAL.'),
    pending_writers='Nonfast start waits3SYS DLY, longer than two RF/packed stages. A fast start needs lu_win, opened by VADV inside a vertex path and closed by any nonTEXCOORD pop; VADV and preceding fast-entry writes are group-only. Packed material pop cannot jump to VADV (PU_MAT DISP stays at its PC); it is drained before that window. Thus no prior arithmetic writer remains when fast RUN begins. FinalDLY writes remain legal and seen before firstM.',
    hold_derivation='After entry all actual arithmetic storage writes come from the audited microcode/collection/owned private RF writers or delayed packed commands. Safe/owned-normal dispatch cannot launch matrix/material/light/table writers; pending prior writers drained. Indexed group/metadata/collection writes are disjoint from arithmetic mirrors. SYS-only mirrors then hold until publication/cancel. CATTR is excluded deliberately because captured lm fixes current mask. Hence reordered read edges see the original sampled arithmetic values; no copied job-wide hold assumption or extra snapshots.',
    limitations='Source composition over legal controller/group ownership, supported by actual frontend/caller trace snapshots; not an automated all-state SAT proof of the complete GX controller or a claim for corrupted live imports. Unqualified generic callers retain old default path. Normal propagation/setup/hold remains open.',
    negative_control=dict(type='Reader negative control only; actual RTL wrong-lane mutation is separately caught',PC=fault,changed_destination='TEXCOORD raw word -> VEC0x020',caught=True))
(out/'contract.json').write_text(json.dumps(result,indent=2)+'\n')
print('CONTRACT_PASS CFG',len(pcs),'PCs',len(seen),'states directarith0/indexedgroupdisjoint; actualABI618paths/prefixexact; pendingwriter/legalownership source derivation, not arbitrary-state SAT')
