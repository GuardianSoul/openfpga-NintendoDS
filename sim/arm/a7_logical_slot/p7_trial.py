"""Test-only P7 logical acceptance; existing service prices are unchanged."""
from pathlib import Path


def patch(source, mutation='none'):
    def replace(old, new):
        nonlocal source
        assert source.count(old) == 1, old
        source = source.replace(old, new, 1)

    replace('module nds_arm7_port #(', 'module nds_arm7_port_slot_trial #(')
    replace('    input  logic        i_consume,', '''    input  logic        i_consume,
    // Sequential ARM MAIN subset. The producer holds valid/address through
    // backpressure. Preparation alone is not presented on these ports.
    input  logic        i_commit_valid,
    input  logic [31:0] i_commit_addr,
    output logic        i_commit_accept,''')
    anchor = '    wire flow_ready = flow_v && flow_a == i_addr[31:2] && flow_left == 5\'d0;'
    replace(anchor, anchor + '''
    // A logical owner can turn over while its independent physical packet
    // still drains. The CPU retains the old finished word itself.
    wire slot_old_consume = i_consume && flow_main && flow_ready;
    assign i_commit_accept = FLOW && i_commit_valid && i_arm
        && i_commit_addr[31:24] == 8'h02 && i_commit_addr[1:0] == 2'd0
        && (!flow_v || slot_old_consume) && !rst && !i_redirect;
''')
    replace('            if (i_req && flow_main && !flow_v) begin',
            '            if (i_req && flow_main && !flow_v && !i_commit_valid) begin')
    capture = '''
            // Consume above clears only the old logical owner. Acceptance
            // then captures one new sequential owner, using existing N/S
            // classification and deadlines, without changing rp_*.
            if (i_commit_accept) begin
                flow_v <= 1'b1; flow_a <= i_commit_addr[31:2];
                flow_qv <= 1'b0;
                flow_left <= !(first_s && n_block != i_commit_addr[31:5]) ? 5'd2 : 5'd16;
                first_s <= 1'b0;
            end
'''
    if mutation == 'drop-capture':
        capture = capture.replace('if (i_commit_accept)', 'if (1\'b0 && i_commit_accept)')
    elif mutation not in ['none', 'consume-wins']:
        raise ValueError(mutation)
    if mutation == 'consume-wins':
        replace('            if (i_consume) begin', capture + '            if (i_consume) begin')
    else:
        replace('            if (il_lookup_kill) flow_qv <= 1\'b0;',
                capture + '            if (il_lookup_kill) flow_qv <= 1\'b0;')
    ledger = Path(__file__).with_name('p7_ledger.svh').read_text()
    replace('    // simulation (+a7dbg):', ledger + '\n    // simulation (+a7dbg):')
    return source
