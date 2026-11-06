#!/usr/bin/env python3
"""Emit exact per-image A dictionaries, retaining the original ROM fallback."""
import argparse
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--write', action='store_true')
p.add_argument('--image', type=Path, help='one newly emitted2048-word image')
a = p.parse_args()
files = [a.image] if a.image else [f for f in sorted((ROOT / 'rtl/gpu3d').glob('gpu3d_gxrom*.sv'))
         if re.fullmatch(r'gpu3d_gxrom(?:_u\w)?\.sv', f.name)]
assert len(files) == (1 if a.image else 7)
assert re.search(r"RESET\s*=\s*11'd40", (ROOT / 'rtl/gpu3d/gpu3d_gxeng.sv').read_text())
for path in files:
    text = path.read_text()
    words = {int(i): int(v, 16) for i, v in re.findall(r"ra\[(\d+)\] = 70'h([0-9a-fA-F]+);", text)}
    assert len(words) == 2048 and sorted(words) == list(range(2048))
    unique = sorted(set(words.values()))
    assert len(unique) <= 1024, (path, len(unique))
    ids = {v: i for i, v in enumerate(unique)}
    index = sum(ids[words[i]] << (10*i) for i in range(2048))
    table = sum(v << (70*i) for i, v in enumerate(unique))
    assert all((table >> (70*((index >> (10*i)) & 1023)) & ((1 << 70)-1)) == words[i] for i in range(2048))
    block = ('    // BEGIN exact A dictionary (tools/gxasm/rom_dictionary.py)\n'
             f'    // {len(unique)} complete70-bit classes; all2048PCs including padding.\n'
             f"    localparam logic [20479:0] A_INDEX_BITS = 20480'h{index:05120x};\n"
             f"    localparam logic [35839:0] A_WORD_LO_BITS = 35840'h{table & ((1<<35840)-1):08960x};\n"
             f"    localparam logic [35839:0] A_WORD_HI_BITS = 35840'h{table >> 35840:08960x};\n"
             f"    localparam logic [69:0] A_RESET_WORD = 70'h{words[40]:018x};\n"
             '    // END exact A dictionary\n')
    text = re.sub(r'    // BEGIN exact A dictionary.*?    // END exact A dictionary\n', '', text, flags=re.S)
    if 'parameter bit A_DICT' not in text:
        text = text.replace("#(parameter bit B2 = 1'b0)", "#(parameter bit B2 = 1'b0, parameter bit A_DICT = 1'b0)", 1)
        text = text.replace('    input  logic        clk,\n', '    input  logic        clk,\n    input  logic        clk2, rst,\n', 1)
        text = text.replace('        a_q <= ra[a_addr[10:0]];\n', '', 1)
        old = '    generate if (B2) begin : g_b2\n'
        new = '''    generate if (A_DICT) begin : g_a_dict
        gpu3d_gxrom_adict #(.INDEX_BITS(A_INDEX_BITS), .WORD_LO_BITS(A_WORD_LO_BITS), .WORD_HI_BITS(A_WORD_HI_BITS), .RESET_WORD(A_RESET_WORD)) u_a (
            .clk, .clk2, .rst, .addr(a_addr), .q(a_q));
    end else begin : g_a_original
        always_ff @(posedge clk) a_q <= ra[a_addr[10:0]];
    end endgenerate
    generate if (B2) begin : g_b2
'''
        assert old in text
        text = text.replace(old, new, 1)
    text = text.replace('.WORD_BITS(A_WORD_BITS)', '.WORD_LO_BITS(A_WORD_LO_BITS), .WORD_HI_BITS(A_WORD_HI_BITS)')
    pos = text.index('    logic [69:0] ra')
    text = text[:pos] + block + text[pos:]
    if path.name == 'gpu3d_gxrom_ux.sv':
        from b_dictionary import decorate
        text = decorate(text)
    if a.write:
        path.write_text(text)
    else:
        assert text == path.read_text(), f'{path}: regenerate with --write'
    print(path.name, 'classes', len(unique), 'full70 roundtrips2048')
