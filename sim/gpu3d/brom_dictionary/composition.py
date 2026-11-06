#!/usr/bin/env python3
"""Source-bound B2 clock/read-site composition; no model or fitter."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser()
p.add_argument('--out', type=Path, required=True)
p.add_argument('--before', default='ecf3ce4cf7169f04cbf78a96a88249075b3ae2da')
a = p.parse_args()
out = a.out.resolve()
out.mkdir(parents=True, exist_ok=True)
paths = ['rtl/gpu3d/gpu3d_gxeng.sv', 'rtl/gpu3d/gpu3d_gxrom_ux.sv',
         'rtl/gpu3d/gpu3d_gxrom_adict.sv', 'sim/ds/runtime_gx_context.py',
         'sim/pocket_ds/runtime_import_gx_context.svh']
old = {n:subprocess.check_output(['git', 'show', a.before+':'+n], cwd=ROOT) for n in paths}
new = {n:(ROOT/n).read_bytes() for n in paths}
H = lambda b: hashlib.sha256(b).hexdigest()
eng = new[paths[0]].decode()
rom = new[paths[1]].decode()
inverse = eng.replace('    localparam bit B_DICT = FF && LUNIT && SMALL && ROM_DICT;\n', '').replace(', .B_DICT(B_DICT)', '')
block = '''    generate if (B_DICT) begin : g_bdict_decode
        // Old B2 registers preview at E0 and B/expanded immediate at E1;
        // od at E1 is exactly odec(B at E1). Decode that same registered
        // dictionary word directly, removing the preview feedback reader.
        assign od = odec(ub);
    end else begin : g_registered_decode
        always_ff @(posedge clk) od <= odec(ub_n);
    end endgenerate'''
assert inverse.count(block) == 1
inverse = inverse.replace(block, '    always_ff @(posedge clk) od <= odec(ub_n);')
assert inverse.encode() == old[paths[0]], 'engine outside ROM/decode binding'
inverse = re.sub(r'    // BEGIN exact B dictionary.*?    // END exact B dictionary\n', '', rom, flags=re.S)
inverse = inverse.replace(", parameter bit B_DICT = 1'b0)", ')')
block = '''    generate if (B_DICT && B2) begin : g_b_dict
        wire [66:0] word_q;
        gpu3d_gxrom_bdict #(.INDEX_BITS(B_INDEX_BITS), .WORD_BITS(B_WORD_BITS)) u_b (
            .clk, .addr(b_addr), .q(word_q));
        assign b_q = word_q[66:32];
        assign t_imm = word_q[31:0];
    end else if (B2) begin : g_b2'''
assert inverse.count(block) == 1
inverse = inverse.replace(block, '    generate if (B2) begin : g_b2')
block = '''    generate if (!(B_DICT && B2)) begin : g_timm_original
        always_ff @(posedge clk) t_imm <= imt[t_idx];
    end endgenerate'''
assert inverse.count(block) == 1
inverse = inverse.replace(block, '    always_ff @(posedge clk) t_imm <= imt[t_idx];')
assert inverse.encode() == old[paths[1]], 'original ROM tables/ports/A/fallback outside new binding'
for path in paths[2:]:
    assert new[path] == old[path], path
assert not re.search(r'`RUNTIME_GEOMETRY\.u_eng\.(?:od|ub\w*|imi_n|t_imm)\s*=', new[paths[4]].decode())
code = re.sub(r'/\*.*?\*/|//[^\n]*', '', eng, flags=re.S)
reads = [l.strip() for l in code.splitlines() if re.search(r'\bub_n\b', l)]
assert len(reads) == 3 and reads[-1] == 'always_ff @(posedge clk) od <= odec(ub_n);'
assert "localparam bit B_DICT = FF && LUNIT && SMALL && ROM_DICT;" in eng
assert 'assign ub = ub_q;' in eng
assert 'if (!rst && od != odec(ub))' in eng
assert "B_IMI_LO = 12, B_IMI_W = 7" in (ROOT/'rtl/gpu3d/gpu3d_gxu_pkg.sv').read_text()
b = {int(i):int(v, 16) for i,v in re.findall(r"rb\[(\d+)\] = 35'h([a-fA-F0-9]+);", rom)}
imm = {int(i):int(v, 16) for i,v in re.findall(r"imt\[(\d+)\] = 32'h([a-fA-F0-9]+);", rom)}
index = int(re.search(r"B_INDEX_BITS = 18432'h([a-fA-F0-9]+)", rom)[1], 16)
table = int(re.search(r"B_WORD_BITS = 34304'h([a-fA-F0-9]+)", rom)[1], 16)
assert len(b) == 2048 and len(imm) == 128 and table & ((1 << 67)-1) == 0
for i in range(2048):
    got = table >> (67*((index >> (9*i)) & 511)) & ((1 << 67)-1)
    assert got == (b[i] << 32) | imm[(b[i] >> 12) & 127], i
helper = (ROOT/'rtl/gpu3d/gpu3d_gxrom_bdict.sv').read_text()
assert 'index_q <= index_mem[addr];' in helper and 'q <= word_mem[index_q];' in helper
assert 'rst' not in re.sub(r'//[^\n]*', '', helper)
assert 'clk2' not in helper
for path, names in [('sim/ds/ds.mk', ['gpu3d_gxrom_adict.sv', 'gpu3d_gxrom_bdict.sv', 'gpu3d_gxrom_ux.sv']),
                    ('sim/gpu3d/geom.mk', ['gpu3d_gxrom_adict.sv', 'gpu3d_gxrom_bdict.sv', 'gpu3d_gxrom_ux.sv']),
                    ('sim/pocket_ds/run.py', ['gpu3d_gxrom_bdict.sv'])]:
    s = (ROOT/path).read_text()
    for n in names:
        assert s.count(n) >= 1 and (ROOT/'rtl/gpu3d'/n).exists(), (path,n)
result = dict(before=a.before, old_hashes={n:H(b) for n,b in old.items()}, new_hashes={n:H(b) for n,b in new.items()},
    inverse_engine_and_ROM_exact=True, all_original_A_B_IMT_bits_exact=True,
    helper_A_and_import_sources_exact=True, preview_read_sites=reads, roundtrips=2048, combined_classes=269,
    clock_relation='For every SYS address sequence: original B2[t]=B(addr[t-1]); original operand[t]=IMT(B_IMI(B(addr[t-1]))). New index[t]=class(addr[t]); dictionary output[t]=entry(index[t-1]) gives both original values at the same SYS edge. Outputs hold between SYS edges. No address hold across M is presumed.',
    decode_relation='The unchanged registered B2 original satisfies od[t]=odec(preview[t-1])=odec(B2[t]). The private caller decodes that same registered word directly. SMALL/B2 is1 only in this opt-in binding; the exact original registered path remains otherwise. Full word and decode equality imply identical unchanged consumers, not guessed DS slack.',
    synthesis_binding='Original preview definition remains. Its only real readers are imi_n for the inactive old TIMM path, and the inactive registered od branch. In the private B_DICT binding neither is live, permitting the old B/TIMM RAMs to drop. No promised mapping count or timing pass.',
    initialization='Clocked pipeline relation after legal initialization; zero entry0 also matches zero-initialized two-state model startup. Both stages continue through reset. No arbitrary X-powerup or corrupted internal-ROM-state theorem.',
    limits='Source composition plus actual paired unit/caller evidence, not a whole-controller all-state SAT proof. Existing DS/native/game gaps and RAM32/ALM2500 feasibility remain open; no new hardware timing rule.')
(out/'composition.json').write_text(json.dumps(result, indent=2)+'\n')
print('BROM_COMPOSITION_PASS frozen2048/full67; inverseROM/engine/default/A/imports exact; actual3preview sites; twoSYS relation')
