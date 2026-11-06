"""Decorate only UX with an optional exact B2/expanded-operand dictionary."""
import re


def decorate(text):
    b = {int(i):int(v, 16) for i,v in re.findall(r"rb\[(\d+)\] = 35'h([a-fA-F0-9]+);", text)}
    imm = {int(i):int(v, 16) for i,v in re.findall(r"imt\[(\d+)\] = 32'h([a-fA-F0-9]+);", text)}
    assert len(b) == 2048 and len(imm) == 128
    unique = sorted({0} | {(v << 32) | imm[(v >> 12) & 127] for v in b.values()})
    assert len(unique) <= 512 and unique[0] == 0
    ids = {v:i for i,v in enumerate(unique)}
    index = sum(ids[(b[i] << 32) | imm[(b[i] >> 12) & 127]] << (9*i) for i in range(2048))
    table = sum(v << (67*i) for i,v in enumerate(unique))
    for i in range(2048):
        word = (table >> (67*((index >> (9*i)) & 511))) & ((1 << 67)-1)
        assert word >> 32 == b[i] and word & 0xffffffff == imm[(b[i] >> 12) & 127]
    text = re.sub(r'    // BEGIN exact B dictionary.*?    // END exact B dictionary\n', '', text, flags=re.S)
    if 'parameter bit B_DICT' not in text:
        old = "parameter bit A_DICT = 1'b0)"
        assert text.count(old) == 1
        text = text.replace(old, "parameter bit A_DICT = 1'b0, parameter bit B_DICT = 1'b0)")
        old = '    generate if (B2) begin : g_b2\n'
        assert text.count(old) == 1
        text = text.replace(old, '''    generate if (B_DICT && B2) begin : g_b_dict
        wire [66:0] word_q;
        gpu3d_gxrom_bdict #(.INDEX_BITS(B_INDEX_BITS), .WORD_BITS(B_WORD_BITS)) u_b (
            .clk, .addr(b_addr), .q(word_q));
        assign b_q = word_q[66:32];
        assign t_imm = word_q[31:0];
    end else if (B2) begin : g_b2
''')
        old = '    always_ff @(posedge clk) t_imm <= imt[t_idx];'
        assert text.count(old) == 1
        text = text.replace(old, '''    generate if (!(B_DICT && B2)) begin : g_timm_original
        always_ff @(posedge clk) t_imm <= imt[t_idx];
    end endgenerate''')
    block = ('    // BEGIN exact B dictionary (tools/gxasm/b_dictionary.py)\n'
             f'    // {len(unique)} complete35-bit B/32-bit operand classes, all2048 PCs.\n'
             f"    localparam logic [18431:0] B_INDEX_BITS = 18432'h{index:04608x};\n"
             f"    localparam logic [34303:0] B_WORD_BITS = 34304'h{table:08576x};\n"
             '    // END exact B dictionary\n')
    pos = text.index('    logic [69:0] ra')
    return text[:pos] + block + text[pos:]
