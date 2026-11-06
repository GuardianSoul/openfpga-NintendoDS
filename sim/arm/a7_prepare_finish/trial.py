"""Test-only CPU phase mapping, with no production file or wait-price change."""

def patch(source, mutation='none'):
    assert source.count('module arm7_ds import') == 1
    source = source.replace('module arm7_ds import', 'module arm7_ds_trial import', 1)
    source = source.replace('  input  logic [31:0] i_rdata,', '  input logic phase_trial,\n  input logic [31:0] i_rdata_in,')
    source = source.replace('  input  logic        i_ok,', '  input logic i_ok_in,')
    anchor = '  wire        if_wait = MAIN_IF_FLOW && !tbit && f_rq && pc_f[31:24] == 8\'h02 && !i_ok && !e_busy;'
    assert source.count(anchor) == 1
    addition = '''
  // An explicitly bounded mapping trial: current prefetch finishes before
  // the first internal START. An advance is not silently an I completion.
  // This has no price/countdown and does not change P7's packet ownership.
  logic phase_f_done, phase_prepared;
  logic [31:2] phase_f_owner;
  logic [31:0] phase_f_word, phase_prepared_address;
  wire phase_class = phase_trial && !tbit && pc_f[31:24] == 8'h02 &&
       ((e_mul && !ins[21] && !ins[20]) || (e_sr && !ins[20]));
  wire phase_owner_live = phase_f_done && phase_f_owner == i_addr[31:2];
  wire i_ok = phase_owner_live || i_ok_in;
  wire [31:0] i_rdata = phase_owner_live ? phase_f_word : i_rdata_in;
  wire phase_f_finish = phase_class && !phase_f_done && f_rq && ph &&
                        run && !halted && i_ok_in;
  wire phase_first_wait = phase_class && esub == 2'd0 && !i_ok;
  wire phase_internal_start = pipe_fire && phase_class &&
                             (e_mul ? (esub == 0 || esub == 1) : esub == 0);
  wire phase_prepare = phase_internal_start && esub == 0;
  // A later actual F offer remains necessary. This indication does not
  // itself allocate, free, retag or pre-read any memory service descriptor.
  wire phase_next_commit = phase_prepared && i_consume && !i_redirect;
  always_ff @(posedge clk) begin
    if (rst || i_redirect || i_consume) begin
      phase_f_done <= 0; phase_f_owner <= '0; phase_f_word <= '0;
      phase_prepared <= 0; phase_prepared_address <= '0;
    end else begin
      if (phase_f_finish) begin
        phase_f_done <= 1; phase_f_owner <= i_addr[31:2];
        phase_f_word <= i_rdata_in;
      end
      if (phase_prepare) begin
        phase_prepared <= 1; phase_prepared_address <= i_addr + 32'd4;
      end
    end
  end
  wire if_wait = (MAIN_IF_FLOW && !tbit && f_rq && pc_f[31:24] == 8'h02 &&
                  !i_ok && !e_busy) || phase_first_wait;
'''
    source = source.replace(anchor, addition)
    if mutation == 'early-internal':
        source = source.replace('wire phase_first_wait = phase_class && esub == 2\'d0 && !i_ok;',
                                'wire phase_first_wait = 1\'b0;')
    elif mutation == 'early-commit':
        source = source.replace('wire phase_next_commit = phase_prepared && i_consume && !i_redirect;',
                                'wire phase_next_commit = phase_prepare && !i_redirect;')
    elif mutation != 'none':
        raise ValueError(mutation)
    return source
