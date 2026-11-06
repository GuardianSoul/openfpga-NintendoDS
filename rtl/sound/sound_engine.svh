// Shared sound decoder/FIFO engine body; included by sound and sound_worker.
    localparam bit MULTI_PARENT = EVENT_MODE && EVENT_FAST && EVENT_WORKERS==4 && WORKER_ID<0;
    localparam int PARENT_SHADOW_LAYOUT = MULTI_PARENT ? 2 : 0;
    localparam bit OWNED_RUNTIME = EVENT_MODE && EVENT_FAST && WORKER_ID>=0 && WORKER_ID<4;
    localparam int OWNED_SHADOW_LAYOUT = OWNED_RUNTIME ? 1 : 0;
    localparam bit WORKER_READ_ONLY = OWNED_RUNTIME && WORKER_CAPTURE_CUT;
    localparam logic [17:0] WORKER_MASK = WORKER_ID<0 ? 18'h3ffff : (18'h01111 << WORKER_ID);
    logic engine_mem_req,engine_mem_we,engine_mem_n4,engine_mem_ack,engine_mem_rvalid;
    logic [24:0] engine_mem_addr;
    logic [31:0] engine_mem_wdata,engine_mem_rdata;
    logic engine_overrun,engine_late;
    logic [3:0] worker_idle,worker_lates,worker_overruns;
    logic signed [27:0] lane_left [4],lane_right [4];
    logic [15:0] lane_sample1 [4],lane_sample3 [4],lane_stop [4];
    logic [4:0] lane_active [4],lane_updates [4];
    logic signed [27:0] lane_postvol0 [4],lane_postvol2 [4];
    logic parent_weight_valid;
    logic signed [27:0] parent_weight_left,parent_weight_right;
    logic worker_reg_pulse,worker_reg_local;
    logic [8:0] worker_reg_addr;
    logic [1:0] worker_reg_size;
    logic [31:0] worker_reg_data;
    wire workers_idle = &worker_idle && !worker_reg_pulse;
    logic pipe_mix_zero;
    // ------------------------------------------------------------ state words
    // Channel entry: w0 SOUNDxCNT (busy and start are flops), w1 source word
    // address, w2 {loop start, timer reload}, w3 length, w4 {loop index,
    // sample, timer}, w5 {timer bit 16, write lap, read lap, FIFO write
    // word, FIFO read byte, position in nibbles} (melonDS can leave the timer
    // at >= 0x10000 when a channel stops), w6 {ADPCM byte, FIFO level, fetch
    // word offset}, w7 {loop value, index, ADPCM value or noise LFSR}.
    // The ADPCM loop state (loop index, loop value) lives only in the RAM
    // row: written through its own byte lanes, read from the row as stored.
    // Capture entry: w1 destination, w2 timer reload, w3 length, w4 timer,
    // w5 position in nibbles, w6 write word offset.
    // Samples go straight into their byte lanes of the unit's 4-word buffer
    // (sound_capbuf);
    // words are written out four at a time, or at the end of the buffer, as
    // melonDS's capture FIFO does, and restarting a unit drops them, as in
    // melonDS. The buffer slot and the byte in the word follow from the
    // position.
    logic [31:0] w0, w1, w2, w3;
    logic [39:0] w4, w5, w6, w7;
    (* preserve *) logic [25:0] w5p;   // w5[25:0] again, only for the RAM's write data
    logic [4:0]  ent;                   // the entry: 0-15 channels, 16-17 captures
    logic [159:0] rr_q, rr_ram_q;        // the entry's run-time row as stored

    logic [6:0]  f_vol;   assign f_vol  = w0[6:0];
    logic [1:0]  f_div;   assign f_div  = w0[9:8];
    logic [6:0]  f_pan;   assign f_pan  = w0[22:16];
    logic [2:0]  f_duty;  assign f_duty = w0[26:24];
    logic [1:0]  f_rep;   assign f_rep  = w0[28:27];
    logic [1:0]  f_fmt;   assign f_fmt  = w0[30:29];
    logic [24:0] f_sad;   assign f_sad  = w1[26:2];
    logic [15:0] f_tmr;   assign f_tmr  = w2[15:0];
    logic [15:0] f_pnt;   assign f_pnt  = w2[31:16];
    logic [20:0] f_len;   assign f_len  = w3[20:0];
    logic        f_t17;   assign f_t17  = w5[38];
    logic [15:0] f_timer; assign f_timer = w4[15:0];
    logic [15:0] f_cs;    assign f_cs   = w4[31:16];
    logic [6:0]  f_idxl;  assign f_idxl = rr_q[38:32];     // the row's w4[38:32]
    logic [25:0] f_pos;   assign f_pos  = w5[25:0];
    logic [4:0]  f_rp;    assign f_rp   = w5[30:26];
    logic [2:0]  f_wp;    assign f_wp   = w5[33:31];
    logic [1:0]  f_rlap;  assign f_rlap = w5[35:34];
    logic [1:0]  f_wlap;  assign f_wlap = w5[37:36];
    logic [21:0] f_roff;  assign f_roff = w6[21:0];
    logic [6:0]  f_level; assign f_level = w6[28:22];
    logic [7:0]  f_byte;  assign f_byte = w6[36:29];
    logic [15:0] f_val;   assign f_val  = w7[15:0];
    logic [6:0]  f_idx;   assign f_idx  = w7[22:16];
    logic [15:0] f_vall;  assign f_vall = rr_q[159:144];   // the row's w7[39:24]

    // ------------------------------------------------------------ global registers
    logic [15:0] soundcnt /*verilator public_flat_rw*/;
    logic [9:0]  bias /*verilator public_flat_rw*/;
    logic [7:0]  capcnt0 /*verilator public_flat_rw*/;
    logic [7:0]  capcnt1 /*verilator public_flat_rw*/;
    logic [1:0]  cap_start;             // capture started; reset at its next run
    logic [15:0] busy /*verilator public_flat_rw*/;    // SOUNDxCNT bit 31
    logic [15:0] keyon /*verilator public_flat_rw*/;   // busy went 0 -> 1: start at the next run

    // ------------------------------------------------------------ RAMs
    // the register words, {word, entry}: one M10K (S_LOAD reads an entry's
    // four words in four clocks)
    logic         cr_we;
    logic [3:0]   cr_be;                // byte lanes
    logic [6:0]   cr_wa, cr_ra;
    logic [31:0]  cr_wd, cr_q, cr_read_q;
    logic [6:0]   cr_read_a;
    sound_cpu_ram #(.AW(7)) u_cpu (.clk, .ce, .we(cr_we), .be(cr_be), .wa(cr_wa), .wd(cr_wd), .ra(cr_ra), .q(cr_q), .ra2(cr_read_a), .q2(cr_read_q));
    logic         rr_we;
    logic [19:0]  rr_be;
    logic [159:0] rr_wd;
    sound_run_ram u_run (.clk, .ce, .we(rr_we), .be(rr_be), .wa(ent), .wd(rr_wd), .ra(ent), .q(rr_ram_q));
    // Prototype: parallel rows remove the four-word working-set refill. The
    // qualified RAMs remain authoritative mirrors for reads/import/default0.
    wire parent_read_valid=ent==1 || ent==3 || ent==16 || ent==17;
    wire [1:0] parent_read_slot=ent[4] ? {1'b1,ent[0]} : {1'b0,ent[1]};
    wire parent_config_valid=cr_wa[4:0]==1 || cr_wa[4:0]==3 || cr_wa[4:0]==16 || cr_wa[4:0]==17;
    wire [1:0] parent_config_slot=cr_wa[4] ? {1'b1,cr_wa[0]} : {1'b0,cr_wa[1]};
    logic [31:0] fast_config [4][32];
    logic [31:0] config_row [4];
    generate if(OWNED_RUNTIME) begin : g_owned_config
        // S_BOUND supplies the same owned slot before every S_LOAD.
        wire owned_read=!ent[4] && ent[1:0]==2'(WORKER_ID);
        wire owned_write=!cr_wa[4] && cr_wa[1:0]==2'(WORKER_ID);
        genvar w,b;
        for(w=0;w<4;w=w+1)begin : g_word
            wire [31:0] raw_row;
            for(b=0;b<4;b=b+1)begin : g_byte
                wire byte_write=cr_we && owned_write && cr_wa[6:5]==2'(w) && cr_be[b];
                wire [7:0] byte_q;
                sound_mlab #(.AW(5),.DW(8)) u_bank (
                    .clk,.ce,.we(byte_write),.wa({3'd0,cr_wa[3:2]}),
                    .wd(cr_wd[8*b+:8]),.ra({3'd0,ent[3:2]}),.q(byte_q));
`ifndef ALTERA_RESERVED_QIS
`ifndef SYNTHESIS
                logic collision_q;
                always_ff @(posedge clk)if(ce)
                    collision_q<=byte_write && cr_wa[3:2]==ent[3:2];
                assign raw_row[8*b+:8]=byte_q ^ {8{collision_q}};
                always_ff @(posedge clk)if(ce && !rst && st==S_LOAD)
                    assert(!collision_q)else $fatal(1,"sound worker config collision consumed");
`else
                assign raw_row[8*b+:8]=byte_q;
`endif
`else
                assign raw_row[8*b+:8]=byte_q;
`endif
            end
            assign config_row[w]=owned_read ? raw_row : 32'bx;
        end
`ifndef ALTERA_RESERVED_QIS
`ifndef SYNTHESIS
        logic read_valid_q;
        logic [1:0] read_slot_q;
        always_ff @(posedge clk)if(ce)begin
            read_valid_q<=owned_read;read_slot_q<=ent[3:2];
            if(!rst && st==S_LOAD)
                assert(owned_read && read_valid_q && read_slot_q==ent[3:2])
                    else $fatal(1,"sound worker config registered read lead");
        end
`endif
`endif
    end else if(MULTI_PARENT)begin : g_parent_config
        // S_BOUND supplies a clean registered read before every S_LOAD.
        // Byte banks retain all four logical rows; u_cpu remains unchanged.
        genvar w,b;
        for(w=0;w<4;w=w+1)begin : g_word
            wire [31:0] raw_row;
            wire word_write=cr_we && parent_config_valid && cr_wa[6:5]==2'(w);
            for(b=0;b<4;b=b+1)begin : g_byte
                sound_mlab #(.AW(5),.DW(8)) u_bank (
                    .clk,.ce,.we(word_write && cr_be[b]),
                    .wa({3'd0,parent_config_slot}),.wd(cr_wd[8*b+:8]),
                    .ra({3'd0,parent_read_slot}),.q(raw_row[8*b+:8]));
            end
            wire [31:0] checked_row;
`ifndef ALTERA_RESERVED_QIS
`ifndef SYNTHESIS
            logic collision_q;
            always_ff @(posedge clk)if(ce)
                collision_q<=word_write && (|cr_be) && parent_config_slot==parent_read_slot;
            // Deliberately poison undefined read-during-write data in simulation.
            assign checked_row=raw_row ^ {32{collision_q}};
            always_ff @(posedge clk)if(ce && !rst && st==S_LOAD)
                assert(!collision_q)else $fatal(1,"sound parent config collision consumed");
`else
            assign checked_row=raw_row;
`endif
`else
            assign checked_row=raw_row;
`endif
            assign config_row[w]=parent_read_valid ? checked_row : 32'bx;
        end
`ifndef ALTERA_RESERVED_QIS
`ifndef SYNTHESIS
        logic read_valid_q;
        logic [1:0] read_slot_q;
        always_ff @(posedge clk)if(ce)begin
            read_valid_q<=parent_read_valid;
            read_slot_q<=parent_read_slot;
            if(!rst && st==S_LOAD)
                assert(parent_read_valid && read_valid_q && read_slot_q==parent_read_slot)
                    else $fatal(1,"sound parent config registered read lead");
        end
`endif
`endif
    end else begin : g_full_config
        genvar w;
        for(w=0;w<4;w++)begin : g_word
            assign config_row[w]=fast_config[w][ent];
        end
    end endgenerate
    logic [159:0] fast_runtime [32];
    logic [159:0] runtime_row;
    logic [15:0] runtime_sample1,runtime_sample3;
    generate if(OWNED_RUNTIME) begin : g_owned_runtime
        // Only the row body is consumed at S_LOAD. Live loop index/value
        // bytes remain asynchronous FF, including their delayed lsv_q writes.
        logic [23:0] loop_state [4];
        logic [15:0] sample1,sample3;
        wire owned=!ent[4] && ent[1:0]==2'(WORKER_ID);
        wire [159:0] raw_row;
        genvar b;
        for(b=0;b<20;b=b+1)begin : g_byte
            if(b==4 || b==18 || b==19)begin : g_loop
                localparam integer LB=b==4 ? 0 : b-17;
                assign raw_row[8*b+:8]=loop_state[ent[3:2]][8*LB+:8];
                always_ff @(posedge clk)if(ce && rr_we && owned && rr_be[b])
                    loop_state[ent[3:2]][8*LB+:8]<=rr_wd[8*b+:8];
            end else begin : g_body
                wire byte_write=rr_we && owned && rr_be[b];
                wire [7:0] byte_q;
                sound_mlab #(.AW(5),.DW(8)) u_bank (
                    .clk,.ce,.we(byte_write),.wa({3'd0,ent[3:2]}),
                    .wd(rr_wd[8*b+:8]),.ra({3'd0,ent[3:2]}),.q(byte_q));
`ifndef ALTERA_RESERVED_QIS
`ifndef SYNTHESIS
                logic collision_q;
                always_ff @(posedge clk)if(ce)collision_q<=byte_write;
                assign raw_row[8*b+:8]=byte_q ^ {8{collision_q}};
                always_ff @(posedge clk)if(ce && !rst && ld)
                    assert(!collision_q)else $fatal(1,"sound worker runtime collision consumed");
`else
                assign raw_row[8*b+:8]=byte_q;
`endif
`else
                assign raw_row[8*b+:8]=byte_q;
`endif
            end
        end
        assign runtime_row=owned ? raw_row : 160'bx;
        assign runtime_sample1=sample1;
        assign runtime_sample3=sample3;
        always_ff @(posedge clk) if(ce && rr_we)begin
            if(ent==1)begin
                if(rr_be[2])sample1[7:0]<=rr_wd[23:16];
                if(rr_be[3])sample1[15:8]<=rr_wd[31:24];
            end
            if(ent==3)begin
                if(rr_be[2])sample3[7:0]<=rr_wd[23:16];
                if(rr_be[3])sample3[15:8]<=rr_wd[31:24];
            end
        end
`ifndef ALTERA_RESERVED_QIS
`ifndef SYNTHESIS
        logic read_valid_q;
        logic [1:0] read_slot_q;
        always_ff @(posedge clk)if(ce)begin
            read_valid_q<=owned;read_slot_q<=ent[3:2];
            if(!rst && ld)
                assert(owned && read_valid_q && read_slot_q==ent[3:2])
                    else $fatal(1,"sound worker runtime registered read lead");
        end
`endif
`endif
`ifndef ALTERA_RESERVED_QIS
        logic [4:0] loop_entry;
        always_ff @(posedge clk) if(ce) begin
            if(lsv_we)loop_entry<=ent;
            if(!rst)begin
                if(ld || rr_we || (itb_go && act==A_LOOP) || (st==S_ITA && adp_upd))
                    assert(owned)else $fatal(1,"sound runtime nonowner/sentinel access");
                if(lsv_q)assert(ent==loop_entry)else $fatal(1,"sound runtime delayed-loop address changed");
            end
        end
`endif
    end else if(MULTI_PARENT)begin : g_parent_runtime
        wire [159:0] raw_row,checked_row;
        logic [15:0] sample1,sample3;
        genvar b;
        for(b=0;b<20;b=b+1)begin : g_byte
            sound_mlab #(.AW(5),.DW(8)) u_bank (
                .clk,.ce,.we(rr_we && parent_read_valid && rr_be[b]),
                .wa({3'd0,parent_read_slot}),.wd(rr_wd[8*b+:8]),
                .ra({3'd0,parent_read_slot}),.q(raw_row[8*b+:8]));
        end
        // Fixed-address public taps cannot use the selected bank read port.
        assign runtime_sample1=sample1;
        assign runtime_sample3=sample3;
        always_ff @(posedge clk)if(ce && rr_we)begin
            if(ent==1)begin
                if(rr_be[2])sample1[7:0]<=rr_wd[23:16];
                if(rr_be[3])sample1[15:8]<=rr_wd[31:24];
            end
            if(ent==3)begin
                if(rr_be[2])sample3[7:0]<=rr_wd[23:16];
                if(rr_be[3])sample3[15:8]<=rr_wd[31:24];
            end
        end
`ifndef ALTERA_RESERVED_QIS
`ifndef SYNTHESIS
        logic collision_q,read_valid_q;
        logic [1:0] read_slot_q;
        always_ff @(posedge clk)if(ce)begin
            collision_q<=rr_we && parent_read_valid && (|rr_be);
            read_valid_q<=parent_read_valid;
            read_slot_q<=parent_read_slot;
            if(!rst)begin
                if(ld || rr_we)assert(parent_read_valid)
                    else $fatal(1,"sound parent runtime noncapture/nonselect access");
                if(st==S_LOAD)assert(read_valid_q && read_slot_q==parent_read_slot && !collision_q)
                    else $fatal(1,"sound parent runtime registered read lead/collision");
                assert(!lsv_q && st!=S_ITA && st!=S_ITB && st!=S_ITC && st!=S_FILL && st!=S_RETAG)
                    else $fatal(1,"sound parent unexpected voice/loop consumer");
                if(st==S_CH)assert(selpass)else $fatal(1,"sound parent unselected channel");
            end
        end
        assign checked_row=raw_row ^ {160{collision_q}};
`else
        assign checked_row=raw_row;
`endif
`else
        assign checked_row=raw_row;
`endif
        assign runtime_row=parent_read_valid ? checked_row : 160'bx;
    end else begin : g_full_runtime
        assign runtime_row=fast_runtime[ent];
        assign runtime_sample1=fast_runtime[1][31:16];
        assign runtime_sample3=fast_runtime[3][31:16];
    end endgenerate
    always_comb begin
        rr_q = EVENT_MODE && EVENT_FAST ? runtime_row : rr_ram_q;
        if(MULTI_PARENT && ent==1)rr_q[31:16]=lane_sample1[1];
        if(MULTI_PARENT && ent==3)rr_q[31:16]=lane_sample3[3];
    end
    generate if(EVENT_MODE && EVENT_FAST) begin : g_fast_rows
        always_ff @(posedge clk) if(ce) begin
            if(!OWNED_RUNTIME && !MULTI_PARENT && cr_we)for(int b=0;b<4;b++)if(cr_be[b])fast_config[cr_wa[6:5]][cr_wa[4:0]][8*b+:8]<=cr_wd[8*b+:8];
            if(!OWNED_RUNTIME && !MULTI_PARENT && rr_we)for(int b=0;b<20;b++)if(rr_be[b])fast_runtime[ent][8*b+:8]<=rr_wd[8*b+:8];
        end
    end endgenerate
    logic         cb_we;
    logic [3:0]   cb_be;
    logic [2:0]   cb_wa, cb_ra;
    logic [31:0]  cb_wd, cb_q;
    sound_capbuf u_cb (.clk, .ce, .we(cb_we), .be(cb_be), .wa(cb_wa), .wd(cb_wd), .ra(cb_ra), .q(cb_q));

    // ADPCM {next index, difference}: the step from the FIFO RAM's upper half,
    // read in the cycle S_ITB completes a decode (the FIFO word is not needed
    // after it), with the address registered beside it
    logic [9:0]  rom_ra, rom_ra_q;
    logic [22:0] rom_q;

    logic        ff_we;
    logic [6:0]  ff_wa;
    logic [7:0]  ff_ra;
    logic [31:0] ff_wd, ff_q;
    sound_ram #(.AW(8), .DW(32), .ADPCM(1)) u_fifo (.clk, .ce, .we(ff_we), .wa({1'b0, ff_wa}), .wd(ff_wd), .ra(ff_ra), .q(ff_q));
    always_ff @(posedge clk) if (ce) rom_ra_q <= rom_ra;
    sound_adpcm_step u_adp (.step(ff_q[14:0]), .ra(rom_ra_q), .q(rom_q));
    logic        tg_we;
    logic [6:0]  tg_wa;
    logic [1:0]  tg_wd, tg_q;
    sound_mlab #(.AW(7), .DW(2), .STYLE("M10K")) u_tag (.clk, .ce, .we(tg_we), .wa(tg_wa), .wd(tg_wd), .ra(ff_ra[6:0]), .q(tg_q));

    // Fetch request queue: {capture write, data, channel, word address, zero,
    // words, FIFO word, lap}. Capture words are one-word write entries.
    localparam int QW = 1 + 32 + 4 + 25 + 1 + 3 + 3 + 2;
    logic          q_we;
    logic [3:0]    q_wa, q_ra;
    logic [QW-1:0] q_wd, q_q;
    // Shallow full-word storage: retain the existing enabled read register.
    // At nonempty/nonfull occupancy the pointers differ; full blocks writes.
    // An empty push may collide, but F_IDLE/F_HEAD supplies a clean read
    // before F_RUN consumes a descriptor. No service or publication edge moves.
    logic [QW-1:0] q_storage_q;
    sound_mlab #(.AW(4), .DW(QW)) u_queue (.clk, .ce, .we(q_we), .wa(q_wa), .wd(q_wd), .ra(q_ra), .q(q_storage_q));
`ifndef ALTERA_RESERVED_QIS
`ifndef SYNTHESIS
    logic q_collision_q;
    always_ff @(posedge clk) if(ce) q_collision_q <= q_we && q_wa==q_ra;
    // MLAB mixed-port collisions are undefined. Poison rather than assuming
    // the M10K's old-data value, and reject any descriptor that consumes it.
    assign q_q = q_storage_q ^ {QW{q_collision_q}};
`else
    assign q_q = q_storage_q;
`endif
`else
    assign q_q = q_storage_q;
`endif
    logic [4:0]    q_cnt;
    logic          q_pop;

    // ------------------------------------------------------------ engine control
    typedef enum logic [4:0] {
        S_CLEAR, S_IDLE, S_BOUND, S_REG, S_REG2, S_LOAD, S_CH, S_RETAG, S_FILL,
        S_ITA, S_ITB, S_ITC, S_CAP, S_CAPA, S_CFL, S_STORE, S_MIX, S_OUT, S_WORK
    } state_t;
    state_t      st /*verilator public_flat_rd*/;
    logic [3:0]  cnt;                   // load/store/mix/output step
    logic [7:0]  clr;
    logic        tick_pend;
    logic        win;                   // a step is being processed
    logic [1:0]  cpu_read;              // independent read pipeline; memory refills never hold MMIO reads
    logic        cpu_rd_accept, reg_take;
    assign cpu_rd_accept = reg_req && !reg_we && !reg_ack && cpu_read == 0 && st != S_CLEAR;
    assign reg_take = cpu_rd_accept || ((st == S_IDLE || (!EVENT_MODE && st == S_BOUND)) && reg_req && reg_we && !reg_ack && event_write_ready);
    logic        reg_ret;               // register access came from S_BOUND
    logic [2:0]  cfl_k, cfl_n;          // capture flush: next and number of words
    logic        cfl_rdy;               // cb_q holds buffered word cfl_k
    logic        cap_wrap;              // flush ends at the end of the buffer
    logic [1:0]  fills;                 // start-up refills left
    logic        dec_fill;              // refill after the ADPCM decode step
    logic        adp_upd;               // the ADPCM value changed: the next S_ITA copies it to the sample
    logic [2:0]  act;
    logic signed [27:0] accl, accr;     // mixer
    logic        selpass;               // output select: channels 1 and 3 mixed again

    localparam logic [2:0] A_NONE = 3'd0, A_READ8 = 3'd1, A_READ16 = 3'd2, A_HDR = 3'd3,
                           A_LOOP = 3'd4, A_DECRD = 3'd5, A_DECSH = 3'd6, A_HOLD = 3'd7;

    logic       e_busy, e_keyon;
    assign e_busy = busy[ent[3:0]];
    assign e_keyon = keyon[ent[3:0]];
    logic       noise_ch;               // channels 14-15 play noise as format 3
    assign noise_ch = ent[3:1] == 3'b111;

    logic [7:0]  ccnt;                  // the capture unit's SNDCAPxCNT
    assign ccnt = ent[0] ? capcnt1 : capcnt0;
    // a capture unit is a looping PCM8 (8-bit) or PCM16 (16-bit) channel
    logic [1:0]  e_fmt, e_rep;
    assign e_fmt = !WORKER_READ_ONLY && ent[4] ? {1'b0, !ccnt[3]} : f_fmt;
    assign e_rep = !WORKER_READ_ONLY && ent[4] ? 2'b01 : f_rep;

    // Multipliers: vp = volume x pan (mix steps 0 and 2, its own DSP
    // half), and the shared one for sample x vp (steps 1 and 3) and the
    // master volume (S_OUT); both registered.
    logic        [7:0]  vp_b;
    (* multstyle = "dsp" *) logic [19:0] vp;
    logic signed [27:0] mul_a;
    logic signed [19:0] mul_b;
    logic signed [47:0] mul_p;
    always_ff @(posedge clk) if (ce) mul_p <= mul_a * mul_b;

    // ------------------------------------------------------------ datapath
    logic [7:0]  vol8, pan8;
    assign vol8 = (f_vol == 7'd127) ? 8'd128 : {1'b0, f_vol};
    assign pan8 = (f_pan == 7'd127) ? 8'd128 : {1'b0, f_pan};
    logic [11:0] vs;                    // volume << shift
    always_comb case (f_div)
        2'd0: vs = {vol8, 4'd0};
        2'd1: vs = {1'b0, vol8, 3'd0};
        2'd2: vs = {2'b0, vol8, 2'd0};
        default: vs = {4'b0, vol8};
    endcase

    // loop start + length, words (a capture length 0 is one word): added at
    // the load from the RAM words, so the refill's address and burst
    // (tot - roff, then sad + roff) don't wait for this carry chain too
    logic [21:0] tot;
    logic        short;                 // under 16 bytes: melonDS's Run plays nothing
    assign short = f_pnt[15:2] == 14'd0 && f_len[20:2] == 19'd0 && {1'b0, f_pnt[1:0]} + {1'b0, f_len[1:0]} < 3'd4;
    logic        inactive;              // S_CH: the channel outputs 0 and keeps its state
    assign inactive = !e_busy || (f_fmt == 2'd3 && !ent[3]) || (f_fmt != 2'd3 && short);

    // Positions count nibbles in every format (a sample is 2 for PCM8, 4 for
    // PCM16, 1 for ADPCM and PSG), so the end and the loop start are the
    // same shift of the word counts for all of them.
    logic [2:0]  pinc;
    assign pinc = (e_fmt == 2'd0) ? 3'd2 : (e_fmt == 2'd1) ? 3'd4 : 3'd1;
    logic [25:0] posn;
    assign posn = f_pos + {23'b0, pinc};
    logic [25:0] lim, lstart;
    assign lim = {1'b0, tot, 3'b0};
    assign lstart = {7'b0, f_pnt, 3'b0};
    logic past_end;
    assign past_end = !posn[25] && (posn >= lim);
    logic sat;                          // position stops counting near the top
    assign sat = (f_pos[25:24] == 2'b01) && f_pos[23:2] == 22'h3FFFFF;
    logic psg_hi;
    assign psg_hi = (f_duty != 3'd7) && ({1'b0, posn[2:0]} + {1'b0, f_duty} >= 4'd7);

    // S_ITA decisions for formats 0-2 (melonDS NextSample_*)
    logic        it_pre;                // still in the start delay (ADPCM: or the header)
    assign it_pre = posn[25] || (f_fmt == 2'd2 && posn < 26'd8);
    logic        it_stop;               // one-shot end
    assign it_stop = past_end && !f_rep[0] && f_rep[1];
    logic        it_loop;
    assign it_loop = past_end && f_rep[0];
    logic [2:0]  it_act;
    always_comb begin
        if (f_fmt == 2'd2) begin
            if (it_pre) it_act = (posn == 26'd0) ? A_HDR : A_NONE;
            else if (past_end) it_act = f_rep[0] ? A_LOOP : A_HOLD;   // (a stop leaves S_ITA)
            else it_act = posn[0] ? A_DECSH : A_DECRD;
        end else it_act = posn[25] ? A_NONE : f_fmt[0] ? A_READ16 : A_READ8;
    end

    // Timer: +512 per step (S_CH, S_CAP), reload + timer - 0x10000 per sample
    logic        tm_tmr;                // start: reload + 512
    assign tm_tmr = (st == S_CH && e_keyon) || (st == S_CAP && cap_start[ent[0]]);
    logic        tm_base_reload;
    assign tm_base_reload=tm_tmr || (EVENT_MODE && (st==S_CH || st==S_CAP));
    logic        tm_reload;
    assign tm_reload = (st == S_ITA) || (st == S_CAPA);
    logic [16:0] tm_sum;
    logic [17:0] tm_s;                  // in a DSP block (nds_dsp_add): the chip is short of LABs
    nds_dsp_add #(.W(17)) u_tma (.clk, .a({f_t17 && !tm_reload && !tm_base_reload, tm_base_reload ? f_tmr : f_timer}),
        .b(tm_reload ? {1'b0, f_tmr} : EVENT_MODE ?
            (tm_tmr || !event_due ? 17'd0 : 17'h10000-{1'b0,f_tmr}) : 17'd512), .s(tm_s));
    // Match the existing unsigned18-bit sum, with no new state or service edge.
    // Keep the forced-DSP parent/default path; unused owned-worker DSPs prune.
    logic [16:0] tm_carry_a,tm_carry_b;
    logic [17:0] tm_carry_s;
    assign tm_carry_a={f_t17 && !tm_reload && !tm_base_reload, tm_base_reload ? f_tmr : f_timer};
    assign tm_carry_b=tm_reload ? {1'b0, f_tmr} : EVENT_MODE ?
        (tm_tmr || !event_due ? 17'd0 : 17'h10000-{1'b0,f_tmr}) : 17'd512;
    assign tm_carry_s={1'b0,tm_carry_a}+{1'b0,tm_carry_b};
    assign tm_sum = OWNED_RUNTIME ? tm_carry_s[16:0] : tm_s[16:0];

    // FIFO data for the read at f_rp
    logic [7:0]  fbyte;
    always_comb case (f_rp[1:0])
        2'd0: fbyte = ff_q[7:0];
        2'd1: fbyte = ff_q[15:8];
        2'd2: fbyte = ff_q[23:16];
        default: fbyte = ff_q[31:24];
    endcase
    logic [15:0] fpcm;                  // the PCM8/PCM16 sample read
    assign fpcm = f_fmt[0] ? (f_rp[1] ? ff_q[31:16] : ff_q[15:0]) : {fbyte, 8'd0};
    logic [6:0]  hdr_idx;
    assign hdr_idx = (ff_q[22:16] > 7'd88) ? 7'd88 : ff_q[22:16];

    // IMA-ADPCM: the nibble is chosen in S_ITB (ROM address), decoded in
    // S_ITC from the ROM's difference and the stored ADPCM byte's low nibble
    logic [3:0]  nib_b;
    assign nib_b = (act == A_DECSH) ? f_byte[7:4] : fbyte[3:0];
    assign rom_ra = {f_idx, nib_b[2:0]};
    logic [3:0]  nib;
    assign nib = f_byte[3:0];
    // f_val -/+ the ROM's difference as one sum: the difference's four
    // step terms (u_adp's, gated with its index check: both from the
    // registered address) each inverted for a subtraction, plus 4 (the four
    // +1s of -(a+b+c+d) = ~a+~b+~c+~d+4): one adder tree from the FIFO RAM's
    // word to w7 instead of the difference's and then the add/subtract
    // (#842: u_fifo -> w7[12] -0.684 ns)
    logic        d_ok;
    assign d_ok = rom_ra_q[9:3] <= 7'd88;
    logic [17:0] dt0, dt1, dt2, dt3;
    assign dt0 = {18{nib[3]}} ^ (d_ok                ? {6'd0, ff_q[14:3]} : 18'd0);
    assign dt1 = {18{nib[3]}} ^ (d_ok && rom_ra_q[0] ? {5'd0, ff_q[14:2]} : 18'd0);
    assign dt2 = {18{nib[3]}} ^ (d_ok && rom_ra_q[1] ? {4'd0, ff_q[14:1]} : 18'd0);
    assign dt3 = {18{nib[3]}} ^ (d_ok && rom_ra_q[2] ? {3'd0, ff_q[14:0]} : 18'd0);
    logic signed [17:0] vsum;
    assign vsum = {{2{f_val[15]}}, f_val} + dt0 + dt1 + dt2 + dt3 + {15'd0, nib[3], 2'b00};
`ifndef ALTERA_RESERVED_QIS
    always @(posedge clk)
        if (!rst && st == S_ITC && vsum !== (nib[3] ? $signed({{2{f_val[15]}}, f_val}) - $signed({2'b0, rom_q[15:0]})
                                                    : $signed({{2{f_val[15]}}, f_val}) + $signed({2'b0, rom_q[15:0]})))
            $display("sound: ERROR: the folded ADPCM sum differs from f_val -/+ the ROM's difference");
`endif
    logic [15:0] vnew;
    // clamp to +-0x7FFF (melonDS): overflow and sign, one function per bit
    logic        v_ovf;
    assign v_ovf = vsum[17] ? (vsum[16:15] != 2'b11 || vsum[14:0] == 15'd0) : (vsum[16:15] != 2'b00);
    assign vnew = WORKER_PIPE && OWNED_RUNTIME ? pipe_decode_sample :
                  v_ovf ? {vsum[17], {14{!vsum[17]}}, 1'b1} : vsum[15:0];
    logic [6:0] inew;
    assign inew = WORKER_PIPE && OWNED_RUNTIME ? pipe_decode_index : rom_q[22:16];
    logic at_loop;                      // position is the loop start nibble
    assign at_loop = (f_pos == lstart);

    logic [2:0]  rsize;                 // bytes consumed by the read
    always_comb case (act)
        A_READ16: rsize = 3'd2;
        A_HDR:    rsize = 3'd4;
        A_DECSH, A_HOLD, A_NONE: rsize = 3'd0;
        default:  rsize = 3'd1;
    endcase
    logic [5:0]  rp_sum;
    assign rp_sum = {1'b0, f_rp} + {3'b0, rsize};
    logic signed [7:0] lev_sub;
    assign lev_sub = $signed({f_level[6], f_level}) - $signed({5'b0, rsize});
    logic [6:0]  lev_new;
    assign lev_new = (lev_sub < -8'sd32) ? 7'h60 : lev_sub[6:0];
    logic need_fill;                    // melonDS refills when 0 <= level <= 16
    assign need_fill = !lev_sub[7] && (lev_sub <= 8'sd16) && rsize != 3'd0;
    // A read that takes the level below zero (manual repeat past the end,
    // where melonDS no longer refills) uses whatever the FIFO holds. A word
    // written in the cycle it is read shows its old tag (the FIFO and tag
    // RAMs read old data, Quartus OLD_DATA), so the engine waits a cycle.
    logic data_ok;
    assign data_ok = (tg_q == f_rlap) || lev_sub[7];
    logic itb_go;                       // S_ITB completes this cycle
    assign itb_go = !MULTI_PARENT && (st == S_ITB) && (act == A_NONE || act == A_DECSH || act == A_HOLD || data_ok);

    // ---- refill (melonDS FIFO_BufferData); also a capture unit's write
    // address and word offset (loop start 0, one word)
    logic [22:0] rdiff;                 // tot - roff; bit 22 = borrow
    assign rdiff = {1'b0, tot} - {1'b0, f_roff};
    logic        roff_end;
    assign roff_end = rdiff[22] || rdiff[21:0] == 22'd0;
    logic [21:0] roff_e;
    assign roff_e = (roff_end && e_rep[0]) ? {6'b0, f_pnt} : f_roff;
    logic        fill_skip;
    assign fill_skip = roff_end && !e_rep[0] && e_rep[1];
    logic [22:0] remain;                // tot - roff_e: after a loop back, the length
    assign remain = (roff_end && e_rep[0]) ? {2'b0, f_len} : rdiff;
    logic [2:0]  burst;
    assign burst = ent[4] ? 3'd1 : (fill_skip || remain[22]) ? 3'd0 :
                   (remain[21:2] == 20'd0) ? {1'b0, remain[1:0]} : 3'd4;
    logic [25:0] faddr;
    assign faddr = {1'b0, f_sad} + {4'b0, roff_e};
    logic [3:0]  wp_sum;
    assign wp_sum = {1'b0, f_wp} + {1'b0, burst};
    logic        fill_go;               // S_FILL commits this cycle
    assign fill_go = !MULTI_PARENT && (st == S_FILL) && (q_cnt != 5'd16 || burst == 3'd0);

    // ---- capture
    logic        acc_r;                 // the right accumulator: mixing step 4, or capture unit 1
    assign acc_r = (st == S_MIX) ? cnt[2] : (st == S_OUT) ? cnt == 4'd1 : ent[0];
    logic signed [27:0] cap_acc;        // (also the mixer adder's input)
    assign cap_acc = acc_r ? accr : accl;
    // DS rule DS_SPU_CAPTURE (docs/hw-reference.md, sndcap v3 DC grid): the
    // sample is (sum >> 7) / 2, halved toward zero (melonDS: sum >> 8): one
    // more when the sum is negative and bit 7 is set
    // The capture unit's side by ent[0] alone (cu_acc): the buffer is written
    // only in S_CAPA, where acc_r is ent[0], so cnt stays off the path to
    // u_cb's data (#1015/#1030/#1031 cnt -> u_cb -0.006..-0.561 ns)
    logic signed [27:0] cu_acc;
    // DS31: capture source bit1 selects channel0/2 after volume/divider,
    // before pan. Keep the unpanned value independently of the mixer sample.
    // Odd fractional rounding of this source is not measured: the existing
    // capture quantizer is the provisional fallback, with a staged hwref probe.
    logic signed [27:0] postvol [2];
    logic signed [28:0] postvol_product;
    logic signed [27:0] postvol0,postvol2;
    // Owned fast workers move the divider's power-of-two scale after both
    // products. Keep all low bits until the existing final truncations.
    generate if(OWNED_RUNTIME)begin : g_worker_volume
        logic signed [23:0] base_product;
        assign base_product=$signed(f_cs)*$signed({1'b0,vol8});
        always_comb case(f_div)
            2'd0:postvol_product=29'(base_product)<<<4;
            2'd1:postvol_product=29'(base_product)<<<3;
            2'd2:postvol_product=29'(base_product)<<<2;
            default:postvol_product=29'(base_product);
        endcase
    end else begin : g_full_volume
        assign postvol_product=$signed(f_cs)*$signed({1'b0,vs});
    end endgenerate
    assign postvol0=MULTI_PARENT?lane_postvol0[0]:postvol[0];
    assign postvol2=MULTI_PARENT?lane_postvol2[2]:postvol[1];
    assign worker_postvol0=postvol[0];assign worker_postvol2=postvol[1];
    always_ff @(posedge clk)if(ce)begin
        if(st==S_MIX && cnt==0 && !selpass && (ent==0 || ent==2))postvol[ent[1]]<=WORKER_PIPE && OWNED_RUNTIME ? (pipe_mix_zero?28'sd0:pipe_weight_postvol) : 28'(postvol_product>>>3);
        if(rst)begin postvol[0]<=0;postvol[1]<=0;end
    end
    assign cu_acc = ccnt[1] ? (ent[0] ? postvol2 : postvol0) : (ent[0] ? accr : accl);
    logic signed [19:0] cap_sh;
    assign cap_sh = cu_acc[27:8] + {19'd0, cu_acc[27] && cu_acc[7]};
    logic [15:0] cap_smp;               // clamp(acc >> 8)
    logic        c_ovf;
    assign c_ovf = cap_sh[19:15] != {5{cap_sh[19]}};
    assign cap_smp = c_ovf ? {cap_sh[19], {15{!cap_sh[19]}}} : cap_sh[15:0];
    // DS rule DS_SPU_CAP8 (docs/hw-reference.md, run 30 sndq S1): the 8-bit
    // sample is (sum >> 15) / 2, halved toward zero, saturated (melonDS:
    // the 16-bit sample's top byte)
    logic signed [11:0] cap8_sh;
    logic [7:0]  cap8;
    logic [12:0] cap8_s, cap8_dsp_s, cap8_carry_s;
    // Workers use the identical combinational increment without a forced DSP.
    // Keep the parent's existing u_c8 instance and every timer adder intact.
    nds_dsp_add #(.W(12)) u_c8 (.clk, .a(cu_acc[27:16]), .b({11'd0, cu_acc[27] && cu_acc[15]}), .s(cap8_dsp_s));
    assign cap8_carry_s = {1'b0, cu_acc[27:16]} + {12'd0, cu_acc[27] && cu_acc[15]};
    assign cap8_s = OWNED_RUNTIME ? cap8_carry_s : cap8_dsp_s;
    assign cap8_sh = cap8_s[11:0];
    assign cap8 = cap8_sh[11:7] != {5{cap8_sh[11]}} ? {cap8_sh[11], {7{!cap8_sh[11]}}} : cap8_sh[7:0];
    logic        cword;                 // this sample completes a word
    assign cword = posn[2:1] == 2'd0;
    logic [1:0]  cslot;                 // the sample's buffer word
    assign cslot = f_pos[4:3];
    logic [4:0]  cbe;                   // and its byte lanes
    assign cbe = ccnt[3] ? (5'b1 << f_pos[2:1]) : (f_pos[2] ? 5'b01100 : 5'b00011);
    logic        capa_go;               // S_CAPA takes a sample this cycle
    assign capa_go = !WORKER_READ_ONLY && (st == S_CAPA) && f_t17;
    logic        cfl_go;                // S_CFL queues a word this cycle
    assign cfl_go = !WORKER_READ_ONLY && (st == S_CFL) && cfl_k != cfl_n && cfl_rdy && q_cnt != 5'd16;
    logic        cap_end;               // the capture position returns to 0
    assign cap_end = !WORKER_READ_ONLY && ((capa_go && past_end && !cword) || (st == S_CFL && cfl_k == cfl_n && cap_wrap));

    // MULTI_PARENT dispatches voice masks to the four workers. Its S_CH
    // entries are output-selection passes only; it never starts/decodes/refills
    // a voice. Static guards below exclude that unused datapath, retaining the
    // same capture/output/select FSM edges and every generic/worker path.
    // Reachability is checked independently of those guards at the dispatcher.

    // ------------------------------------------------------------ register access decode
    // melonDS SPU::Write8/16/32: up to two byte-enabled RAM writes per access.
    logic        op1_v, op2_v;
    logic [6:0]  op1_a, op2_a;
    logic [3:0]  op1_be;
    logic        rd_ram;                // read returns a RAM word
    logic [6:0]  rd_a;

    logic [3:0] r_ch;   assign r_ch = reg_addr[7:4];
    logic [3:0] r_off;  assign r_off = reg_addr[3:0];
    logic       r_glob; assign r_glob = reg_addr[8];
    logic [7:0] r_ga;   assign r_ga = reg_addr[7:0];
    logic [6:0] r_cap;  assign r_cap = {4'b1000, r_ga[3], 2'b00};   // capture 0/1 entry
    localparam logic [31:0] CNTM = 32'hFF7F837F;
    logic        cap_tmr;               // SOUND1TMR / SOUND3TMR also set the capture timers
    assign cap_tmr = (r_ch == 4'd1) || (r_ch == 4'd3);
    assign op2_a = {4'b1000, r_ch[1], 2'd2};
    logic        cnt_hi;                // the write reaches SOUNDxCNT bit 31
    assign cnt_hi = op1_v && !r_glob && op1_a[1:0] == 2'd0 && op1_be[3];

    always_comb begin
        op1_v = 1'b0; op1_a = {1'b0, r_ch, 2'd0}; op1_be = 4'b0;
        op2_v = 1'b0;
        rd_ram = 1'b0; rd_a = {1'b0, r_ch, 2'd0};
        if (reg_we && !r_glob) begin
            // 8-bit: SOUNDxCNT bytes only. 16-bit: every halfword but SAD's.
            // 32-bit: every word. LEN keeps bits above 20 that nothing reads,
            // so its halves use the same lanes as the others.
            op1_a[1:0] = (reg_size == 2'd0) ? 2'd0 : r_off[3:2];
            case (reg_size)
                2'd0: begin op1_v = r_off[3:2] == 2'd0; op1_be = 4'b1 << r_off[1:0]; end
                2'd1: begin op1_v = r_off[3:2] != 2'd1; op1_be = r_off[1] ? 4'b1100 : 4'b0011; end
                default: begin op1_v = 1'b1; op1_be = 4'b1111; end
            endcase
            op2_v = cap_tmr && reg_size != 2'd0 && r_off[3:2] == 2'd2 && !(reg_size == 2'd1 && r_off[1]);
        end else if (reg_we) begin
            // capture DAD/LEN; SOUNDCNT, SOUNDBIAS and SNDCAPCNT are flops
            if (reg_size == 2'd2 && (r_ga == 8'h10 || r_ga == 8'h18)) begin
                op1_v = 1'b1; op1_a = r_cap | 7'd1; op1_be = 4'b1111;
            end
            if (reg_size != 2'd0 && (r_ga == 8'h14 || r_ga == 8'h1C)) begin
                op1_v = 1'b1; op1_a = r_cap | 7'd3; op1_be = 4'b0011;
            end
        end else if (!r_glob) begin
            rd_ram = 1'b1;
        end else if (r_ga == 8'h10 || r_ga == 8'h18) begin
            rd_ram = 1'b1; rd_a = r_cap | 7'd1;
        end
    end

    // read data: the aligned word (melonDS SPU::Read32; its 8/16-bit reads
    // are the same lanes except for a few registers games do not read that way)
    logic [31:0] rd_word;
    assign reg_rdata = rd_word;
    always_comb begin
        rd_word = 32'd0;
        if (!r_glob) begin
            if (r_off[3:2] == 2'd0) rd_word = {busy[r_ch], cr_read_q[30:0]} & CNTM;   // word 0
        end else case (r_ga[4:2])
            3'd0: rd_word = {16'b0, soundcnt};
            3'd1: rd_word = {22'b0, bias};
            3'd2: rd_word = {16'b0, capcnt1, capcnt0};
            3'd4, 3'd6: rd_word = cr_read_q & 32'h07FFFFFC;           // the capture's word 1
            default: ;
        endcase
    end

    function automatic logic [7:0] capset(input logic [7:0] v);
        logic [7:0] r;
        r = v & 8'h8F;
        if (!r[7]) r[0] = 1'b0;
        return r;
    endfunction

    // Ordered physical events. Due and control-refresh masks are distinct:
    // a start initializes the old runtime/FIFO without an early +512 sample.
    logic [17:0] event_due_mask,event_refresh,event_restart;
    logic [17:0] event_mask,event_work_due;
    logic event_output,event_due;
    // A stopped channel's data-only configuration has one register owner.
    // Timer/CNT/global writes and any capture/output marker keep the full fence.
    logic event_local_write;
    wire inactive_config_write=MULTI_PARENT && reg_req && reg_we && !r_glob &&
        op1_v && !op2_v && !busy[r_ch] && !capcnt0[7] && !capcnt1[7] &&
        (op1_a[1:0]==2'd1 || op1_a[1:0]==2'd3 ||
         (op1_a[1:0]==2'd2 && !(|op1_be[1:0])));
    wire write_worker_ready=event_local_write ?
        (worker_idle[r_ch[1:0]] && !worker_reg_pulse) : workers_idle;

    assign event_due=event_work_due[ent];
    always_comb begin
        event_refresh='0;event_restart='0;
        if(st==S_REG && reg_we) begin
            if(op1_v && !r_glob && op1_a[1:0]==0) begin
                event_refresh[r_ch]=1;
                if(cnt_hi && reg_wdata[31] && !busy[r_ch])event_restart[r_ch]=1;
            end
            if(r_glob && r_ga==8'h00) begin event_refresh[1]=1;event_refresh[3]=1;end
            if(r_glob && (r_ga==8'h08 || r_ga==8'h09)) begin
                for(int u=0;u<2;u++) begin
                    if((reg_size!=0 || r_ga[0]==u[0]) && reg_wdata[u*8+7] && !(u?capcnt1[7]:capcnt0[7])) begin
                        event_refresh[16+u]=1;event_restart[16+u]=1;
                    end
                end
            end
        end
    end
    generate if(EVENT_MODE && WORKER_ID<0) begin : g_event_timers
        sound_event_timers #(.TIMER_DIV(TIMER_DIV)) bank(.clk,.ce,.rst,.run(soundcnt[15]),.sync_tick(tick),
            .enabled({capcnt1[7],capcnt0[7],busy}),.restart(event_restart),
            .config_we(cr_we && cr_wa[6:5]==2),.config_addr(cr_wa[4:0]),.config_be(cr_be[1:0]),.config_data(cr_wd[15:0]),.due(event_due_mask));
    end else begin : g_no_event_timers
        assign event_due_mask='0;
    end endgenerate
    logic [37:0] event_head;
    logic event_write_queued,event_write_due;
    wire event_write_marker=EVENT_MODE && EVENT_FAST && WORKER_ID<0 && reg_req && reg_we && !reg_ack && !event_write_queued && st!=S_CLEAR;
    logic [7:0] event_wp,event_rp;
    logic [8:0] event_count;
    logic event_head_valid;
    wire event_push=EVENT_MODE && (WORKER_ID>=0 ? worker_kick && |((worker_due_mask|worker_refresh_mask)&WORKER_MASK) : (tick || |event_due_mask || |event_refresh || event_write_marker));
    wire event_pop=EVENT_MODE && st==S_IDLE && !(reg_req && reg_we && !reg_ack && event_write_ready) && event_count!=0 && event_head_valid;
    logic event_overflow;
    logic [9:0] event_outputs_pending;
    wire event_output_done=st==S_OUT && cnt==2;
    wire event_write_ready=!EVENT_MODE || WORKER_ID>=0 || (EVENT_FAST ? event_write_due : event_count==0);
    wire event_accept=event_push && (event_count!=256 || event_pop);
    wire [37:0] event_input=WORKER_ID>=0 ? {2'b00,worker_due_mask&WORKER_MASK,worker_refresh_mask&WORKER_MASK} : {event_write_marker,tick,event_due_mask,event_refresh};
    wire [7:0] event_next_rp=event_rp+8'(event_pop);
    // Keep the registered old-data read separate from head forwarding so the
    // 256-entry read mux/storage maps to the existing synchronous sound RAM.
    // Both RAM and forwarding registers advance on this same enabled edge;
    // there is no extra head stage or change to empty/last-pop publication.
    logic [37:0] event_ram_q,event_forward;
    logic event_bypass;
    wire event_forward_now=EVENT_MODE && EVENT_FAST && event_accept && event_next_rp==event_wp;
    sound_ram #(.AW(8), .DW(38), .STYLE(WORKER_ID >= 0 ? "M10K" : "AUTO")) u_events (.clk,.ce,.we(event_accept),.wa(event_wp),.wd(event_input),
        .ra(EVENT_MODE && EVENT_FAST ? event_next_rp : event_rp),.q(event_ram_q));
    always_ff @(posedge clk) if(ce) begin
        event_bypass<=event_forward_now;
        if(event_forward_now)event_forward<=event_input;
    end
    assign event_head=event_bypass ? event_forward : event_ram_q;
    always_ff @(posedge clk) if(ce) begin
        event_outputs_pending<=event_outputs_pending+10'(tick && EVENT_MODE)-10'(event_output_done && EVENT_MODE);
        if(EVENT_MODE && EVENT_FAST)begin
            // Prefetch the successor on the consuming edge. A newly accepted
            // empty/last-pop head bypasses RAM read-during-write explicitly.
            // Each logical event and MMIO marker still retires in FIFO order.
            event_head_valid<=(event_count+9'(event_accept)-9'(event_pop))!=0;
        end else begin
            event_head_valid<=event_count!=0;
        end
        if(event_accept) begin
            event_wp<=event_wp+1'b1;
        end
        if(event_pop)event_local_write<=inactive_config_write && event_head[37] &&
            !event_head[36] && !(|(event_head[35:18]&18'h30000)) && !(|(event_head[17:0]&18'h30000));
        if(event_pop) begin event_rp<=event_rp+1'b1;if(!(EVENT_MODE && EVENT_FAST))event_head_valid<=0;end
        event_count<=event_count+9'(event_accept)-9'(event_pop);
        if(event_push && event_count==256 && !event_pop)event_overflow<=1;
        if(event_write_marker)event_write_queued<=1;
        if(event_pop && event_head[37])event_write_due<=1;
        if(st==S_REG)begin event_write_due<=0;event_local_write<=0;end
        if(reg_ack)event_write_queued<=0;
        if(rst)begin event_write_queued<=0;event_write_due<=0;event_wp<=0;event_rp<=0;event_count<=0;event_head_valid<=0;event_overflow<=0;event_outputs_pending<=0;event_local_write<=0;end
    end
    function automatic logic [4:0] fast_next(input logic [4:0] first,input logic [17:0] mask);
        logic found;
        begin
            fast_next=18;found=0;
            for(int n=0;n<18;n++)if(!found && n>=int'(first) && mask[n])begin fast_next=5'(n);found=1;end
        end
    endfunction
    // Current contribution per voice. Capture latches their live sum after all
    // earlier voice events; output-select still uses the existing second pass.
    localparam int EVENT_ROWS=OWNED_RUNTIME ? 4 : 16;
    wire [3:0] event_slot=OWNED_RUNTIME ? {2'b00,ent[3:2]} : ent[3:0];
    logic signed [27:0] event_left [EVENT_ROWS],event_right [EVENT_ROWS];
    logic signed [27:0] event_sum_left,event_sum_right;
    always_comb begin
        event_sum_left=0;event_sum_right=0;
        if(MULTI_PARENT)for(int n=0;n<4;n++)begin event_sum_left+=lane_left[n];event_sum_right+=lane_right[n];end
        else for(int n=0;n<EVENT_ROWS;n++)begin event_sum_left+=event_left[n];event_sum_right+=event_right[n];end
    end
    logic signed [27:0] fast_left,fast_right;
    logic signed [47:0] fast_lp,fast_rp;
    generate if(OWNED_RUNTIME)begin : g_worker_pan_scale
        logic signed [32:0] base_pan;
        assign base_pan=$signed(g_worker_volume.base_product)*$signed(9'(128-pan8));
        always_comb case(f_div)
            2'd0:fast_lp=48'(base_pan)<<<4;
            2'd1:fast_lp=48'(base_pan)<<<3;
            2'd2:fast_lp=48'(base_pan)<<<2;
            default:fast_lp=48'(base_pan);
        endcase
    end else begin : g_full_pan_scale
        assign fast_lp=$signed(postvol_product)*$signed(9'(128-pan8));
    end endgenerate
    always_comb begin
        // Reuse the unpanned product; derive the other side before rounding.
        // The scale moves past multiplication only; pan sharing is unchanged.
        fast_rp=(48'(postvol_product)<<<7)-fast_lp;
        if(MULTI_PARENT && PARENT_MIX_PIPE)begin
            fast_left=pipe_mix_zero?28'sd0:parent_weight_left;
            fast_right=pipe_mix_zero?28'sd0:parent_weight_right;
        end else begin
            fast_left=WORKER_PIPE && OWNED_RUNTIME ? (pipe_mix_zero?28'sd0:pipe_weight_left) : {{2{fast_lp[35]}},fast_lp[35:10]};
            fast_right=WORKER_PIPE && OWNED_RUNTIME ? (pipe_mix_zero?28'sd0:pipe_weight_right) : {{2{fast_rp[35]}},fast_rp[35:10]};
        end
    end
    always_ff @(posedge clk) if(ce) begin
        if(EVENT_MODE && EVENT_FAST && st==S_MIX && !selpass)begin
            event_left[event_slot]<=mix_ex?28'sd0:fast_left;
            event_right[event_slot]<=mix_ex?28'sd0:fast_right;
        end else if(EVENT_MODE && st==S_MIX && !selpass) begin
            if(cnt==2)event_left[event_slot]<=mix_ex?28'sd0:cx;
            if(cnt==4)event_right[event_slot]<=mix_ex?28'sd0:cx;
        end
        if(rst)for(int n=0;n<EVENT_ROWS;n++)begin event_left[n]<=0;event_right[n]<=0;end
    end

    wire engine_active=st!=S_IDLE && st!=S_CLEAR && st!=S_REG && st!=S_REG2;
    wire engine_decoding=st==S_ITC;
    assign service_active=MULTI_PARENT ? {engine_active,lane_active[3][0],lane_active[2][0],lane_active[1][0],lane_active[0][0]} : {4'b0,engine_active};
    assign service_updates=MULTI_PARENT ? {engine_decoding,lane_updates[3][0],lane_updates[2][0],lane_updates[1][0],lane_updates[0][0]} : {4'b0,engine_decoding};
    assign worker_ready=st==S_IDLE && event_count==0 && !reg_req;
    assign worker_left=event_sum_left;
    assign worker_right=event_sum_right;
    assign worker_sample1=runtime_sample1;
    assign worker_sample3=runtime_sample3;
    always_comb begin
        worker_stop=0;
        if(st==S_ITA && f_t17 && f_fmt!=3 && it_stop)worker_stop[ent[3:0]]=1;
    end
    generate if(WORKER_PIPE && OWNED_RUNTIME)begin : g_pipe_head
        logic [3:0] serial;
        logic last_write,last_tag_write;
        logic [6:0] last_wa,last_ta;
        logic [7:0] last_ra;
        logic [31:0] last_wd;
        logic [1:0] last_td;
        always_ff @(posedge clk)if(ce)begin
            last_ra<=ff_ra;last_write<=ff_we;last_tag_write<=tg_we;
            if(ff_we)begin last_wa<=ff_wa;last_wd<=ff_wd;end
            if(tg_we)begin last_ta<=tg_wa;last_td<=tg_wd;end
            if(st==S_ITC || st==S_MIX)serial<=serial+4'd1;
            if(rst)begin serial<=0;last_write<=0;last_tag_write<=0;last_ra<=8'hff;end
        end
        wire [6:0] head_a={ent[3:0],f_rp[4:2]};
        wire [31:0] next_word=last_write && last_wa==head_a?last_wd:ff_q;
        wire [1:0] next_tag=last_tag_write && last_ta==head_a?last_td:tg_q;
        wire next_word_known=last_ra=={1'b0,head_a} || (last_write && last_wa==head_a);
        wire [2:0] next_act;
        assign next_act[0]=st==S_ITA?it_act[0]:act[0];
        assign next_act[1]=st==S_ITA?it_act[1]:act[1];
        assign next_act[2]=st==S_ITA?it_act[2]:act[2];
        wire [31:0] selected_word=st==S_ITB && itb_go?ff_q:next_word;
        wire [31:0] shifted_word=selected_word >> {f_rp[1:0],3'd0};
        wire signed [7:0] predicted_level=$signed({f_level[6],f_level})-8'sd1;
        wire next_ready=next_word_known && (next_tag==f_rlap || predicted_level[7]);
        wire decode_head=((st==S_ITA && f_t17 && !it_stop) || st==S_ITB) && f_fmt==2 &&
                         (next_act==A_DECRD || next_act==A_DECSH);
        wire decode_ready=next_act==A_DECSH || (st==S_ITB && itb_go) || next_ready;
        wire weight_head=(st==S_ITA && (!f_t17 || it_stop)) || st==S_STORE || st==S_MIX;
        wire signed [15:0] final_sample=st==S_ITA && it_stop && f_t17?16'sd0:
                                             st==S_ITA && adp_upd?f_val:f_cs;
        wire [1:0] deadline=decode_head?(st==S_ITB && itb_go?2'd1:2'd2):
                                          st==S_MIX?2'd0:st==S_STORE?2'd1:2'd2;
        wire [3:0] next_nibble=next_act==A_DECSH?f_byte[7:4]:shifted_word[3:0];
        assign pipe_job={17'd0,serial,decode_head,deadline,decode_head?f_val:final_sample,
                         f_idx,next_nibble,f_vol,f_pan,f_div};
        assign pipe_request=!rst && ((decode_head && decode_ready) || (weight_head && final_sample!=0));
        assign pipe_mix_zero=f_cs==0;
`ifndef ALTERA_RESERVED_QIS
        always_ff @(posedge clk)if(ce && !rst)begin
            if(st==S_ITC)begin
                assert(pipe_decode_valid)else $fatal(1,"SOUND_PIPE_DECODE_DEADLINE owner%0d serial%0d",WORKER_ID,serial);
                assert(vnew===(v_ovf?{vsum[17],{14{!vsum[17]}},1'b1}:vsum[15:0]) && inew===rom_q[22:16])
                    else $fatal(1,"SOUND_PIPE_PREDICTED_OPERAND owner%0d serial%0d",WORKER_ID,serial);
            end
            if(st==S_MIX)begin
                assert(pipe_weight_valid || pipe_mix_zero)else $fatal(1,"SOUND_PIPE_WEIGHT_DEADLINE owner%0d serial%0d",WORKER_ID,serial);
                assert(fast_left==={{2{fast_lp[35]}},fast_lp[35:10]} && fast_right==={{2{fast_rp[35]}},fast_rp[35:10]})
                    else $fatal(1,"SOUND_PIPE_WEIGHT_CONTEXT owner%0d serial%0d",WORKER_ID,serial);
            end
        end
`endif
    end else if(MULTI_PARENT && PARENT_MIX_PIPE)begin : g_parent_pipe_head
        logic [3:0] serial;
        logic [15:0] sample_value;
        logic [31:0] config_value;
        logic [1:0] deadline;
        always_ff @(posedge clk)if(ce)begin
            if(st==S_MIX)serial<=serial+4'd1;
            if(rst)serial<=0;
        end
        always_comb begin
            sample_value=f_cs;config_value=w0;deadline=0;
            if(st==S_LOAD)begin
                // Exactly the row/tap and configuration consumed by S_LOAD.
                sample_value=rr_q[31:16];config_value=config_row[0];deadline=2;
            end else if(st==S_CH)deadline=1;
        end
        assign pipe_request=!rst && selpass && (ent==1 || ent==3) &&
                            (st==S_LOAD || st==S_CH || st==S_MIX) && sample_value!=0;
        assign pipe_job={17'd0,serial,1'b0,deadline,sample_value,7'd0,4'd0,
                         config_value[6:0],config_value[22:16],config_value[9:8]};
        assign pipe_mix_zero=f_cs==0;
`ifndef ALTERA_RESERVED_QIS
        always_ff @(posedge clk)if(ce && !rst && st==S_MIX)begin
            assert(selpass && (ent==1 || ent==3))else $fatal(1,"parent weighted pipe nonselection consumer");
            assert(parent_weight_valid || pipe_mix_zero)else $fatal(1,"PARENT_PIPE_WEIGHT_DEADLINE ent%0d",ent);
            assert(fast_left==={{2{fast_lp[35]}},fast_lp[35:10]} && fast_right==={{2{fast_rp[35]}},fast_rp[35:10]})
                else $fatal(1,"PARENT_PIPE_WEIGHT_CONTEXT ent%0d",ent);
        end
`endif
    end else begin : g_no_pipe_head
        assign pipe_request=0;assign pipe_job=0;assign pipe_mix_zero=0;
    end endgenerate
    // Four existing decoder/FIFO workers share a tagged in-order memory port.
    // Voice events can run ahead independently. Capture/output/MMIO markers
    // stop dispatch until all earlier worker jobs have committed their samples.
    generate
`ifndef SOUND_WORKER_BODY
    if(MULTI_PARENT)begin : g_workers
        logic [4:0] req,we,n4,ack,rvalid;
        logic [24:0] address [5];
        logic [31:0] data [5];
        logic [2:0] pointer,selected,held;
        logic hold_valid,found;
        logic [4:0] arb_ahead,arb_pick;
        logic arb_pointer_known;
        logic [2:0] response_owner [32];
        logic [4:0] response_wp,response_rp;
        logic [5:0] response_count;
        logic [4:0] pipe_request_v,pipe_dv,pipe_wv;
        logic [66:0] pipe_jobs[5];
        logic [15:0] pipe_ds[5];
        logic [6:0] pipe_di[5];
        logic signed [27:0] pipe_wl[5],pipe_wr[5],pipe_wp[5];
        assign pipe_request_v[4]=pipe_request;assign pipe_jobs[4]=pipe_job;
        assign parent_weight_valid=pipe_wv[4];
        assign parent_weight_left=pipe_wl[4];assign parent_weight_right=pipe_wr[4];
        if(WORKER_PIPE || PARENT_MIX_PIPE)begin : g_pipe
            sound_pipe_group #(.CLIENTS(5)) group(.clk_2x,.ce,.rst,.request(pipe_request_v),.job(pipe_jobs),
                .decode_valid(pipe_dv),.weight_valid(pipe_wv),.decode_sample(pipe_ds),.decode_index(pipe_di),
                .weight_left(pipe_wl),.weight_right(pipe_wr),.weight_postvol(pipe_wp));
`ifndef ALTERA_RESERVED_QIS
            // Output selection follows the full S_WORK logical-worker fence.
            // Fetchers/refills remain independent and may still own memory.
            always_ff @(posedge clk_2x)if(ce && !rst && pipe_request_v[4])
                assert(!( |pipe_request_v[3:0]))else $fatal(1,"parent selection overlaps logical arithmetic head");
`endif
        end else begin : g_no_pipe
            assign pipe_dv=0;assign pipe_wv=0;
            genvar p;
            for(p=0;p<5;p=p+1)begin : g_zero
                assign pipe_ds[p]=0;assign pipe_di[p]=0;assign pipe_wl[p]=0;assign pipe_wr[p]=0;assign pipe_wp[p]=0;
            end
        end
        assign req[4]=engine_mem_req;assign we[4]=engine_mem_we;assign n4[4]=engine_mem_n4;
        assign address[4]=engine_mem_addr;assign data[4]=engine_mem_wdata;
        assign engine_mem_ack=ack[4];assign engine_mem_rvalid=rvalid[4];assign engine_mem_rdata=mem_rdata;
        genvar g;
        for(g=0;g<4;g=g+1)begin : lane
            sound_worker #(.CLEAR_REGS(CLEAR_REGS),.EVENT_MODE(1),.EVENT_FAST(1),.EVENT_WORKERS(1),.MEM_QUAD(MEM_QUAD),.WORKER_ID(g),.WORKER_CAPTURE_CUT(WORKER_CAPTURE_CUT),.WORKER_PIPE(WORKER_PIPE),.TIMER_DIV(TIMER_DIV)) engine(
                .clk,.clk_2x,.ce,.rst,.tick(1'b0),.power,
                .reg_req(worker_reg_pulse && (!worker_reg_local || worker_reg_addr[5:4]==2'(g))),.reg_we(1'b1),.reg_addr(worker_reg_addr),.reg_size(worker_reg_size),.reg_wdata(worker_reg_data),.reg_ack(),.reg_rdata(),
                .mem_req(req[g]),.mem_we(we[g]),.mem_n4(n4[g]),.mem_addr(address[g]),.mem_wdata(data[g]),.mem_ack(ack[g]),.mem_rvalid(rvalid[g]),.mem_rdata,
                .out_valid(),.out_l(),.out_r(),.dac_l(),.dac_r(),.overrun(worker_overruns[g]),.late(worker_lates[g]),
                .worker_kick(event_pop),.worker_due_mask(event_head[35:18]),.worker_refresh_mask(event_head[17:0]),.worker_ready(worker_idle[g]),
                .worker_left(lane_left[g]),.worker_right(lane_right[g]),.worker_sample1(lane_sample1[g]),.worker_sample3(lane_sample3[g]),.worker_stop(lane_stop[g]),.service_active(lane_active[g]),.service_updates(lane_updates[g]),.worker_postvol0(lane_postvol0[g]),.worker_postvol2(lane_postvol2[g]),
                .pipe_request(pipe_request_v[g]),.pipe_job(pipe_jobs[g]),
                .pipe_decode_valid(pipe_dv[g]),.pipe_weight_valid(pipe_wv[g]),.pipe_decode_sample(pipe_ds[g]),.pipe_decode_index(pipe_di[g]),
                .pipe_weight_left(pipe_wl[g]),.pipe_weight_right(pipe_wr[g]),.pipe_weight_postvol(pipe_wp[g])
            );
        end
`ifndef ALTERA_RESERVED_QIS
        initial begin
            if(lane[0].engine.WORKER_ID!=0 || lane[1].engine.WORKER_ID!=1 || lane[2].engine.WORKER_ID!=2 || lane[3].engine.WORKER_ID!=3)
                $fatal(1,"sound worker IDs misrouted");
            if(!lane[0].engine.EVENT_FAST || !lane[1].engine.EVENT_FAST || !lane[2].engine.EVENT_FAST || !lane[3].engine.EVENT_FAST)
                $fatal(1,"sound worker fast backend dropped");
            if(lane[0].engine.MEM_QUAD!=MEM_QUAD || lane[1].engine.MEM_QUAD!=MEM_QUAD || lane[2].engine.MEM_QUAD!=MEM_QUAD || lane[3].engine.MEM_QUAD!=MEM_QUAD)
                $fatal(1,"sound worker MEM_QUAD route dropped");
            $display("SOUND_SERVICE_ROUTE_OK four workers IDs0/1/2/3 FAST1");
        end
        always_ff @(posedge clk)if(ce && !rst)begin
            if(mem_rvalid && response_count==0)$fatal(1,"sound orphan memory response");
            if(response_count>32)$fatal(1,"sound response credit overflow");
            if(mem_req && mem_n4 && (mem_we || mem_addr[1:0]!=0 || mem_addr[24:22]!=3'd2))$fatal(1,"sound illegal quad descriptor");
        end
`endif
        always_comb begin
            // Same circular first-request rule, using fixed masks instead of
            // five variable modulo/index chains. No grant state or edge moves.
            // The extra encoded pointer values preserve the original modulo
            // mapping too. Keep the original expression for an unknown
            // simulation pointer; this default is unreachable in binary logic.
            arb_ahead=0;arb_pointer_known=1;
            case(pointer)
                3'd0,3'd5:arb_ahead=req;
                3'd1,3'd6:arb_ahead=req & 5'b11110;
                3'd2,3'd7:arb_ahead=req & 5'b11100;
                3'd3:arb_ahead=req & 5'b11000;
                3'd4:arb_ahead=req & 5'b10000;
                default:arb_pointer_known=0;
            endcase
            if(|arb_ahead)arb_pick=arb_ahead;else arb_pick=req;
            selected=held;found=hold_valid;
            if(!arb_pointer_known)begin
                for(int k=0;k<5;k++)if(!found && req[(int'(pointer)+k)%5])begin selected=3'((int'(pointer)+k)%5);found=1;end
            end else if(!hold_valid)begin
                if(arb_pick[0])begin selected=0;found=1;end
                else if(arb_pick[1])begin selected=1;found=1;end
                else if(arb_pick[2])begin selected=2;found=1;end
                else if(arb_pick[3])begin selected=3;found=1;end
                else if(arb_pick[4])begin selected=4;found=1;end
            end
            mem_req=found && req[selected] && (we[selected] || response_count <= (n4[selected]?6'd28:6'd31));
            mem_n4=found && !we[selected] && n4[selected];
            mem_we=we[selected];mem_addr=address[selected];mem_wdata=data[selected];ack=0;rvalid=0;
            if(mem_req && mem_ack)ack[selected]=1;
            if(mem_rvalid && response_count!=0)rvalid[response_owner[response_rp]]=1;
        end
        always_ff @(posedge clk)if(ce)begin
            if(mem_req && !mem_ack)begin held<=selected;hold_valid<=1;end
            if(mem_req && mem_ack)begin hold_valid<=0;pointer<=selected==4?3'd0:selected+1'b1;end
            if(mem_req && mem_ack && !mem_we)begin
                response_owner[response_wp]<=selected;
                if(mem_n4)for(int k=1;k<4;k++)response_owner[5'(response_wp+5'(k))]<=selected;
                response_wp<=response_wp+(mem_n4?5'd4:5'd1);
            end
            if(mem_rvalid)response_rp<=response_rp+1'b1;
            response_count<=response_count+(mem_req && mem_ack && !mem_we ? (mem_n4?6'd4:6'd1):6'd0)-6'(mem_rvalid);
            if(rst)begin pointer<=0;held<=0;hold_valid<=0;response_wp<=0;response_rp<=0;response_count<=0;end
        end
        assign overrun=engine_overrun || |worker_overruns;
        assign late=engine_late || |worker_lates;
    end else
`endif
    begin : g_single_worker
        assign parent_weight_valid=0;assign parent_weight_left=0;assign parent_weight_right=0;
        assign mem_req=engine_mem_req;assign mem_we=engine_mem_we;assign mem_n4=engine_mem_n4;assign mem_addr=engine_mem_addr;assign mem_wdata=engine_mem_wdata;
        assign engine_mem_ack=mem_ack;assign engine_mem_rvalid=mem_rvalid;assign engine_mem_rdata=mem_rdata;
        assign overrun=engine_overrun;assign late=engine_late;
        assign worker_idle='1;assign worker_lates=0;assign worker_overruns=0;
        genvar k;
        for(k=0;k<4;k=k+1)begin : unused_lane
            assign lane_left[k]=0;assign lane_right[k]=0;assign lane_sample1[k]=0;assign lane_sample3[k]=0;assign lane_stop[k]=0;assign lane_active[k]=0;assign lane_updates[k]=0;assign lane_postvol0[k]=0;assign lane_postvol2[k]=0;
        end
    end endgenerate
    always_ff @(posedge clk)if(ce)begin
        worker_reg_pulse<=MULTI_PARENT && st==S_REG && reg_we;
        if(st==S_REG)worker_reg_local<=event_local_write;
        if(st==S_REG && reg_we)begin worker_reg_addr<=reg_addr;worker_reg_size<=reg_size;worker_reg_data<=reg_wdata;end
        if(rst)begin worker_reg_pulse<=0;worker_reg_local<=0;end
    end

`ifndef ALTERA_RESERVED_QIS
`ifndef SYNTHESIS
    generate if(MULTI_PARENT)begin : g_parent_dispatch_contract
        always_ff @(posedge clk)if(ce && !rst)begin
            assert(st!=S_ITA && st!=S_ITB && st!=S_ITC && st!=S_FILL && st!=S_RETAG)
                else $fatal(1,"sound parent voice dispatch escaped");
            if(st==S_CH || (st==S_LOAD && !ent[4]))
                assert(selpass && (ent==1 || ent==3))
                    else $fatal(1,"sound parent voice load without selection");
            if(event_pop)assert(st==S_IDLE)
                else $fatal(1,"sound parent dispatch outside idle");
            if(st==S_BOUND && !selpass)assert(ent>=16 && ent<=18 && !(|event_mask[15:0]))
                else $fatal(1,"sound parent unmasked voice work");
            if(q_we)assert(cfl_go && ent[4] && !fill_go)
                else $fatal(1,"sound parent read descriptor produced");
            if(fs==F_RUN)assert(h_we && !h_zero && h_n==1)
                else $fatal(1,"sound parent read descriptor consumed");
        end
    end endgenerate
`endif
`endif

    // Owned workers receive voice-only masks. The parent executes captures
    // and output selection. Exclude unused capture consumers without changing
    // any voice/refill/ready edge; postvol0/2 and contribution taps stay live.
`ifndef ALTERA_RESERVED_QIS
`ifndef SYNTHESIS
    generate if(OWNED_RUNTIME)begin : g_worker_read_contract
        always_ff @(posedge clk)if(ce && !rst)begin
            assert(!selpass && !event_output && !(|(event_mask & ~WORKER_MASK)))
                else $fatal(1,"sound worker nonvoice event/selection");
            assert(st!=S_CAP && st!=S_CAPA && st!=S_CFL && st!=S_OUT && st!=S_WORK)
                else $fatal(1,"sound worker capture dispatch escaped");
            if(st==S_LOAD || st==S_CH || st==S_RETAG || st==S_FILL ||
               st==S_ITA || st==S_ITB || st==S_ITC || st==S_STORE || st==S_MIX)
                assert(!ent[4] && ent[1:0]==2'(WORKER_ID))
                    else $fatal(1,"sound worker nonowned active entry");
            if(q_we)assert(st==S_FILL && !ent[4] && !q_wd[QW-1])
                else $fatal(1,"sound worker write descriptor produced");
            if(fs==F_RUN)assert(!h_we)
                else $fatal(1,"sound worker write descriptor consumed");
        end
    end endgenerate
`endif
`endif

    // ------------------------------------------------------------ RAM ports
    // A register write reaches word op_a[1:0] of row op_a[6:2]; every word
    // of the row gets the same data, the byte lanes pick the word.
    logic [6:0]  op_a;
    logic [3:0]  op_be;
    assign op_a = (st == S_REG2) ? op2_a : op1_a;
    assign op_be = (st == S_REG2) ? 4'b0011 : op1_be;
    assign cr_read_a = {rd_a[1:0], rd_a[6:2]};
    assign cr_ra = (st == S_REG || st == S_REG2) ? {rd_a[1:0], rd_a[6:2]} : {cnt[1:0], ent};   // held: reg_rdata reads cr_q with reg_ack; S_LOAD: word cnt
    logic        clearing;
    assign clearing = CLEAR_REGS && st == S_CLEAR;
    assign cr_we = clearing || (st == S_REG2 && reg_we) || (st == S_REG && reg_we && op1_v);
    assign cr_wa = clearing ? clr[6:0] : {op_a[1:0], op_a[6:2]};
    assign cr_be = clearing ? 4'hF : op_be;
    assign cr_wd = clearing ? 32'd0 : reg_wdata;   // SAD/DAD kept as written; the engine uses bits 26:2
    assign cb_we = capa_go;
    assign cb_be = cb_f8 ? 4'(4'b1 << f_pos[2:1]) : (f_pos[2] ? 4'b1100 : 4'b0011);   // (cbe with the registered format)
    // The capture sample and the unit's half of the address come from
    // registers (cb_d, cb_e0, #1061 ent[0] -> u_cb -0.188 ns): during a
    // capture entry ent, the format and both accumulators hold from S_LOAD
    // on (the mixing and the second pass run outside it), so the value a
    // clock before S_CAPA's write is the same (a simulation check below)
    logic [31:0] cb_d;
    logic        cb_e0, cb_f8;
    wire  [31:0] cb_dn = ccnt[3] ? {4{cap8}} : {cap_smp, cap_smp};
    always_ff @(posedge clk) if (ce) begin cb_d <= cb_dn; cb_e0 <= ent[0]; cb_f8 <= ccnt[3]; end
`ifndef ALTERA_RESERVED_QIS
    always_ff @(posedge clk) if (ce && !rst && cb_we && (cb_d != cb_dn || cb_e0 != ent[0] || cb_f8 != ccnt[3]))
        $error("sound: capture data or unit changed in the clock before its write");
`endif
    assign cb_wa = {cb_e0, cslot};
    assign cb_wd = cb_d;
    assign cb_ra = {ent[0], cfl_k[1:0]};
    // Run-time words need no clearing: a start sets every field before use.
    // The store writes every lane but the loop state's (4, 18, 19); the
    // header and the loop point write only those.
    logic        lsv_we, lsv_itc;
    assign lsv_itc = !MULTI_PARENT && (st == S_ITC);
    assign lsv_we = (itb_go && act == A_HDR) || (lsv_itc && at_loop);
    // the loop state goes to the RAM a clock later, from registers (#743:
    // the FIFO RAM's output into u_run's write data missed by 0.032 ns at
    // ce = 1); its lanes are its own, and S_STORE comes two clocks later at
    // the earliest
    logic        lsv_q;
    logic [15:0] lsv_v;
    logic [6:0]  lsv_i;
    always_ff @(posedge clk) if (ce) begin
        lsv_q <= lsv_we;
        lsv_v <= lsv_itc ? vnew : ff_q[15:0];
        lsv_i <= lsv_itc ? inew : hdr_idx;
    end
    assign rr_we = (st == S_STORE) || lsv_q;
    assign rr_be = ((st == S_STORE) ? 20'h3FFEF : 20'h0) | (lsv_q ? 20'hC0010 : 20'h0);
    // the position goes to the RAM from its own copy (w5p): w5[25:0] drives
    // the position adder and compares, and at ce = 1 its route to the RAM
    // missed by 0.094 ns (#731)
    assign rr_wd = {lsv_v, w7[23:0], w6, w5[39:26], w5p, 1'b0, lsv_i, w4[31:0]};
    assign ff_ra = itb_go && (act == A_DECRD || act == A_DECSH) ? {1'b1, rom_ra[9:3]}
                                                                : {1'b0, ent[3:0], f_rp[4:2]};

    // ------------------------------------------------------------ working-set field updates
    // Each field: one assignment from an encoded source choice.
    logic        ld;                    // S_LOAD: the rows arrive
    assign ld = (st == S_LOAD) && cnt == (EVENT_MODE && EVENT_FAST ? 4'd0 : 4'd1);
    logic        ch_start;              // S_CH: melonDS SPUChannel::Start
    assign ch_start = !MULTI_PARENT && (st == S_CH) && !inactive && e_keyon && !selpass;
    logic        ita_go;                // S_ITA takes a sample
    assign ita_go = !MULTI_PARENT && (st == S_ITA) && f_t17;
    logic        cap_go;                // S_CAP: a started unit resets
    assign cap_go = !WORKER_READ_ONLY && (st == S_CAP) && cap_start[ent[0]];

    // w4: timer, sample, loop index
    logic        tm_en;
    assign tm_en = (st == S_CH && !selpass) || (st == S_CAP) || ita_go || capa_go;
    // Sources: a constant (0, or a PSG/noise level), the PCM read, the
    // ADPCM value: with the load, four inputs.
    typedef enum logic [1:0] { CS_HOLD, CS_CONST, CS_PCM, CS_ADP } cs_t;
    cs_t         cs_sel;
    logic        cs_zero;               // the constant is 0 (start, inactive, one-shot end)
    assign cs_zero = !(ita_go && f_fmt == 2'd3);
    always_comb begin
        cs_sel = CS_HOLD;
        if ((st == S_CH && (inactive || (e_keyon && !selpass))) || (ita_go && (f_fmt == 2'd3 || it_stop))) cs_sel = CS_CONST;
        else if (itb_go && (act == A_READ8 || act == A_READ16)) cs_sel = CS_PCM;
        // (A_HOLD needs no write: past the end of a manual-repeat sample the
        // sample already equals the ADPCM value, as every path there decodes)
        else if (!MULTI_PARENT && st == S_ITA && adp_upd) cs_sel = CS_ADP;
    end
    logic        psg_neg;               // PSG/noise sample is -0x7FFF
    assign psg_neg = noise_ch ? f_val[0] : !psg_hi;
    logic [15:0] adp_cs;                // the ADPCM value after a decode or a loop restore
    assign adp_cs = (st == S_ITC) ? vnew : f_vall;

    // w5: position
    // Sources: a constant (a start's -3 samples, PSG -1; or 0), the next
    // position, the loop start: with the load, four inputs.
    typedef enum logic [1:0] { PS_HOLD, PS_CONST, PS_POSN, PS_LSTART } ps_t;
    ps_t         ps_sel;
    logic [3:0]  ps_const;              // low bits of the constant (the rest are its sign)
    assign ps_const = !ch_start ? 4'h0 : (f_fmt == 2'd0) ? 4'hA : (f_fmt == 2'd1) ? 4'h4 :
                      (f_fmt == 2'd2) ? 4'hD : 4'hF;
    always_comb begin
        ps_sel = PS_HOLD;
        if (ch_start || cap_go || cap_end) ps_sel = PS_CONST;
        else if (capa_go) ps_sel = PS_POSN;
        else if (ita_go) begin
            if (f_fmt == 2'd3) ps_sel = noise_ch ? PS_HOLD : PS_POSN;
            else if (it_loop) ps_sel = PS_LSTART;
            else if (!sat) ps_sel = PS_POSN;
        end
    end

    // w6: word offset (refill offset, or a capture's write offset)
    logic        roff_zero, roff_sum;
    assign roff_zero = ch_start || cap_go;
    assign roff_sum = fill_go || cfl_go;

    always_ff @(posedge clk) if (ce) begin
        // register words (load only)
        // words 0-3 arrive in S_LOAD's clocks 1-4
        if(EVENT_MODE && EVENT_FAST && st==S_LOAD)begin
            w0<=config_row[0];w1<=config_row[1];
            w2<=config_row[2];w3<=config_row[3];
            tot<={6'b0,config_row[2][31:16]}+{1'b0,config_row[3][20:0]}+22'(ent[4] && config_row[3][20:0]==0);
        end else if (st == S_LOAD && cnt == 4'd1) w0 <= cr_q;
        if (!(EVENT_MODE && EVENT_FAST) && st == S_LOAD && cnt == 4'd2) w1 <= cr_q;
        if (!(EVENT_MODE && EVENT_FAST) && st == S_LOAD && cnt == 4'd3) w2 <= cr_q;
        if (!(EVENT_MODE && EVENT_FAST) && st == S_LOAD && cnt == 4'd4) begin
            w3 <= cr_q;
            tot <= {6'b0, w2[31:16]} + {1'b0, cr_q[20:0]} + {21'b0, ent[4] && cr_q[20:0] == 21'd0};
        end

        // w4
        if (ld) w4 <= rr_q[39:0];
        else begin
            if (tm_en) {w5[38], w4[15:0]} <= tm_sum;
            case (cs_sel)
                CS_CONST: w4[31:16] <= cs_zero ? 16'd0 : psg_neg ? 16'h8001 : 16'h7FFF;
                CS_PCM:  w4[31:16] <= fpcm;
                CS_ADP:  w4[31:16] <= f_val;   // the sample follows the ADPCM value one cycle later
                default: ;
            endcase
        end

        // w5
        if (ld) begin w5 <= rr_q[79:40]; w5p <= rr_q[65:40]; end
        else begin
            case (ps_sel)
                PS_CONST:  begin w5[25:0] <= {{22{ch_start}}, ps_const}; w5p <= {{22{ch_start}}, ps_const}; end
                PS_POSN:   begin w5[25:0] <= posn; w5p <= posn; end
                PS_LSTART: begin w5[25:0] <= lstart; w5p <= lstart; end
                default: ;
            endcase
            if (ch_start) w5[30:26] <= 5'd0;
            else if (itb_go) w5[30:26] <= rp_sum[4:0];
            if (ch_start) w5[33:31] <= 3'd0;
            else if (fill_go) w5[33:31] <= wp_sum[2:0];
            if (ch_start && f_fmt != 2'd3) w5[35:34] <= f_wlap + 2'd1;
            else if (itb_go && rp_sum[5]) w5[35:34] <= f_rlap + 2'd1;
            if ((ch_start && f_fmt != 2'd3) || (fill_go && wp_sum[3])) w5[37:36] <= f_wlap + 2'd1;
        end

        // w6
        if (ld) w6 <= rr_q[119:80];
        else begin
            if (roff_zero) w6[21:0] <= 22'd0;
            else if (roff_sum) w6[21:0] <= roff_e + {19'b0, burst};
            if (ch_start) w6[28:22] <= 7'd0;
            else if (fill_go) w6[28:22] <= f_level + {2'b0, burst, 2'b0};
            else if (itb_go) w6[28:22] <= lev_new;
            if (itb_go && (act == A_LOOP || act == A_DECRD)) w6[36:29] <= fbyte;
            else if (itb_go && act == A_DECSH) w6[36:29] <= {4'd0, f_byte[7:4]};
        end

        // w7
        if (ld) w7 <= rr_q[159:120];
        else begin
            // sources: the noise LFSR (0x7FFF at a start), the header, the
            // loop or decoded value
            if (ch_start || (ita_go && f_fmt == 2'd3 && noise_ch))
                w7[15:0] <= ch_start ? 16'h7FFF : f_val[0] ? ({1'b0, f_val[15:1]} ^ 16'h6000) : {1'b0, f_val[15:1]};
            else if (itb_go && act == A_HDR) w7[15:0] <= ff_q[15:0];
            else if ((itb_go && act == A_LOOP) || lsv_itc) w7[15:0] <= adp_cs;
            if (itb_go && act == A_HDR) w7[22:16] <= hdr_idx;
            else if (itb_go && act == A_LOOP) w7[22:16] <= f_idxl;
            else if (lsv_itc) w7[22:16] <= inew;
        end
    end

    // ------------------------------------------------------------ mixer
    // melonDS PanOutput: left products in S_MIX step 2, right in step 4.
    // Channels 1 and 3 can leave the mixer (SOUNDCNT 12/13). The output
    // select (SOUNDCNT 8-11) is a second pass after the captures: the
    // selected sides are cleared and channels 1 and 3 are mixed into them
    // again from their stored samples.
    logic signed [25:0] contrib;
    assign contrib = mul_p[35:10];
    logic signed [27:0] cx;
    assign cx = {{2{contrib[25]}}, contrib};
    logic [1:0]  lsel, rsel;
    assign lsel = soundcnt[9:8];
    assign rsel = soundcnt[11:10];
    logic        sel_go;                // S_BOUND after the captures: start the second pass
    assign sel_go = (st == S_BOUND) && !(reg_req && reg_we && !reg_ack && !(EVENT_MODE && EVENT_FAST)) && ent == 5'd18 && (lsel != 2'd0 || rsel != 2'd0);
    logic        mix_ex;                // channel 1/3 left out of the mixer
    assign mix_ex = (ent == 5'd1 && soundcnt[12]) || (ent == 5'd3 && soundcnt[13]);
    logic        mix_l, mix_r, acc_clr;
    assign mix_l = (st == S_MIX) && cnt == 4'd2 && (selpass ? (ent[1] ? lsel[1] : lsel[0]) : !mix_ex);
    assign mix_r = (st == S_MIX) && cnt == 4'd4 && (selpass ? (ent[1] ? rsel[1] : rsel[0]) : !mix_ex);
    assign acc_clr = !EVENT_MODE && (st == S_IDLE) && !(reg_req && reg_we && !reg_ack) && tick_pend;
    logic signed [27:0] acc_sum;        // one adder for both sides
    assign acc_sum = cap_acc + cx;
    always_ff @(posedge clk) if (ce) begin
        if (sel_go && lsel != 2'd0 && (!EVENT_MODE || event_output)) accl <= '0;
        else if (EVENT_MODE && st==S_BOUND && !selpass) accl<=event_sum_left;
        else if (acc_clr) accl <= '0;
        else if(EVENT_MODE && EVENT_FAST && selpass && st==S_MIX && (ent[1]?lsel[1]:lsel[0]))accl<=accl+fast_left;
        else if (mix_l && (!EVENT_MODE || (selpass && !EVENT_FAST))) accl <= acc_sum;
        if (sel_go && rsel != 2'd0 && (!EVENT_MODE || event_output)) accr <= '0;
        else if (EVENT_MODE && st==S_BOUND && !selpass) accr<=event_sum_right;
        else if (acc_clr) accr <= '0;
        else if(EVENT_MODE && EVENT_FAST && selpass && st==S_MIX && (ent[1]?rsel[1]:rsel[0]))accr<=accr+fast_right;
        else if (mix_r && (!EVENT_MODE || (selpass && !EVENT_FAST))) accr <= acc_sum;
    end

    assign vp_b = cnt[1] ? pan8 : 8'd128 - pan8;   // step 0: 128 - pan, step 2: pan
    always_ff @(posedge clk) if (ce) vp <= MULTI_PARENT && PARENT_MIX_PIPE?20'd0:vs * vp_b;
    always_comb begin
        mul_a = '0; mul_b = '0;
        case (st)
            // vs*(128-pan), cs*that, vs*pan, cs*that; products one cycle later
            S_MIX: if(!(MULTI_PARENT && PARENT_MIX_PIPE))begin mul_a = {{12{f_cs[15]}}, f_cs}; mul_b = vp; end
            S_OUT: begin
                mul_a = EVENT_MODE && !soundcnt[15] ? 28'sd0 : cap_acc; // retain master-off bias path
                mul_b = {12'b0, (soundcnt[6:0] == 7'd127) ? 8'd128 : {1'b0, soundcnt[6:0]}};
            end
            default: ;
        endcase
    end

    // final output
    logic signed [20:0] mo;             // (side * master) >> 15
    assign mo = mul_p[35:15];
    logic signed [21:0] mob;
    assign mob = {mo[20], mo} + $signed({6'b0, bias, 6'b0}) - 22'sd32768;
    logic [15:0] mclamp;
    logic        m_ovf;
    assign m_ovf = mob[21:15] != {7{mob[21]}};
    assign mclamp = m_ovf ? {mob[21], {15{!mob[21]}}} : mob[15:0];

    // ------------------------------------------------------------ engine sequence
    always_ff @(posedge clk) if (ce) begin
        reg_ack <= 1'b0;
        out_valid <= 1'b0;
        // Same three-edge acceptance-to-observed-ACK latency as the old idle
        // read path, on a separate RAM read port. Engine work keeps running.
        if (cpu_read != 0) begin
            cpu_read <= cpu_read - 1'b1;
            if (cpu_read == 1) reg_ack <= 1'b1;
        end else if (cpu_rd_accept) cpu_read <= 2;

        if(MULTI_PARENT)busy<=busy & ~(lane_stop[0]|lane_stop[1]|lane_stop[2]|lane_stop[3]);
        case (st)
            S_CLEAR: begin
                clr <= clr + 8'd1;
                if (clr == (CLEAR_REGS ? 8'h7F : 8'h1F)) st <= S_IDLE;
            end

            S_IDLE: begin
                if (reg_req && reg_we && !reg_ack && event_write_ready) begin
                    st <= S_REG; reg_ret <= 1'b0;
                end else if (event_pop) begin
                    event_mask<=event_head[17:0]|event_head[35:18];event_work_due<=event_head[35:18];event_output<=event_head[36];
                    win<=1;ent<=EVENT_FAST ? fast_next(0,(event_head[17:0]|event_head[35:18]) & (MULTI_PARENT?18'h30000:18'h3ffff)):5'd0;cnt<=0;
                    if(MULTI_PARENT)begin
                        event_mask<=(event_head[17:0]|event_head[35:18])&18'h30000;
                        if(event_head[36] || event_head[37] || |(event_head[35:18]&18'h30000) || |(event_head[17:0]&18'h30000))st<=S_WORK;
                        else begin st<=S_IDLE;win<=0;end
                    end else st<=S_BOUND;
                end else if (!EVENT_MODE && tick_pend) begin
                    tick_pend <= 1'b0;
                    win <= 1'b1;
                    ent <= 5'd0;
                    st <= soundcnt[15] ? S_BOUND : S_OUT;
                    cnt <= 4'd0;
                end
            end

            S_WORK: if(write_worker_ready)st<=S_BOUND;

            // between entries: serve a pending register write first
            S_BOUND: begin
                cnt <= 4'd0;
                if (!EVENT_MODE && reg_req && reg_we && !reg_ack) begin
                    st <= S_REG; reg_ret <= 1'b1;
                end else if (sel_go && (!EVENT_MODE || event_output)) begin
                    selpass <= 1'b1;
                    ent <= 5'd1;
                end else if (ent == 5'd18 || (selpass && ent == 5'd5)) begin
                    if(!EVENT_MODE || event_output)st<=S_OUT;else begin win<=0;st<=S_IDLE;end
                end
                else if (EVENT_MODE && !selpass && !event_mask[ent]) ent<=EVENT_FAST?fast_next(ent,event_mask):ent+1'b1;
                else if (ent[4] && !ccnt[7]) ent <= ent + 5'd1;
                else st <= S_LOAD;
            end

            // Register writes reach RAM here (capture timer copy in S_REG2).
            // Reads use cpu_read without interrupting the engine.
            S_REG: begin
                if (!reg_we && rd_ram) st <= S_REG2;
                else begin
                    if (reg_we && r_glob) begin
                        case (reg_size)
                            2'd0: case (r_ga)
                                8'h00: soundcnt[7:0] <= {1'b0, reg_wdata[6:0]};
                                8'h01: soundcnt[15:8] <= reg_wdata[15:8] & 8'hBF;
                                8'h08: begin capcnt0 <= capset(reg_wdata[7:0]); if (reg_wdata[7] && !capcnt0[7]) cap_start[0] <= 1'b1; end
                                8'h09: begin capcnt1 <= capset(reg_wdata[15:8]); if (reg_wdata[15] && !capcnt1[7]) cap_start[1] <= 1'b1; end
                                default: ;
                            endcase
                            default: case (r_ga)
                                8'h00: soundcnt <= reg_wdata[15:0] & 16'hBF7F;
                                8'h04: bias <= reg_wdata[9:0];
                                8'h08: begin
                                    capcnt0 <= capset(reg_wdata[7:0]); if (reg_wdata[7] && !capcnt0[7]) cap_start[0] <= 1'b1;
                                    capcnt1 <= capset(reg_wdata[15:8]); if (reg_wdata[15] && !capcnt1[7]) cap_start[1] <= 1'b1;
                                end
                                default: ;
                            endcase
                        endcase
                    end
                    // SOUNDxCNT bit 31: busy 0 -> 1 requests a start
                    if (reg_we && cnt_hi) begin
                        busy[r_ch] <= reg_wdata[31];
                        if (reg_wdata[31] && !busy[r_ch]) keyon[r_ch] <= 1'b1;
                    end
                    if (reg_we && op2_v) st <= S_REG2;
                    else begin
                        reg_ack <= 1'b1;
                        st <= reg_ret ? S_BOUND : S_IDLE;
                    end
                end
            end

            S_REG2: begin
                reg_ack <= 1'b1;
                st <= reg_ret ? S_BOUND : S_IDLE;
            end


            // two cycles: address, then both rows
            // five cycles: the register words one per clock, the run row with word 0
            S_LOAD: begin
                cnt <= cnt + 4'd1;
                if ((EVENT_MODE && EVENT_FAST) || cnt == 4'd4) st <= !WORKER_READ_ONLY && ent[4] ? S_CAP : S_CH;
            end

            S_CH: begin
                cnt <= 4'd0;
                fills <= 2'd2;
                if (MULTI_PARENT || inactive || selpass) st <= S_MIX;   // not stored: an inactive channel mixes 0
                else if (e_keyon) begin
                    keyon[ent[3:0]] <= 1'b0;
                    st <= (f_fmt == 2'd3) ? S_ITA : S_RETAG;   // PSG and noise read no FIFO
                end else st <= S_ITA;
            end

            // the channel's FIFO words become the old lap (tg_we when the fetcher is not writing)
            S_RETAG: if (!ff_we) begin
                cnt <= cnt + 4'd1;
                if (cnt == 4'd7) st <= S_FILL;
            end

            S_FILL: if (fill_go) begin
                if (fills != 2'd0) begin
                    fills <= fills - 2'd1;
                    if (fills == 2'd1) st <= S_ITA;
                end else st <= S_ITA;
            end

            S_ITA: begin
                act <= it_act;
                adp_upd <= 1'b0;
                if (!f_t17) st <= S_STORE;
                else if (f_fmt == 2'd3) st <= S_ITA;
                else if (it_stop) begin
                    busy[ent[3:0]] <= 1'b0;
                    st <= S_STORE;
                end else st <= S_ITB;
            end

            S_ITB: if (itb_go) begin
                if (act == A_LOOP) adp_upd <= 1'b1;
                st <= (act == A_DECRD || act == A_DECSH) ? S_ITC : need_fill ? S_FILL : S_ITA;
                dec_fill <= need_fill;
                fills <= 2'd0;
            end

            S_ITC: begin
                st <= dec_fill ? S_FILL : S_ITA;
                adp_upd <= 1'b1;
            end

            // capture unit (melonDS SPUCaptureUnit::Run)
            S_CAP: begin
                if (cap_start[ent[0]]) cap_start[ent[0]] <= 1'b0;
                st <= S_CAPA;
            end

            S_CAPA: if (!f_t17) st <= S_STORE;
            else begin
                cfl_k <= 3'd0; cfl_rdy <= 1'b0; cap_wrap <= past_end;
                cfl_n <= {1'b0, cslot} + 3'd1;
                if (cword && (cslot == 2'd3 || past_end)) st <= S_CFL;
                else if (past_end && ccnt[2]) begin
                    if (ent[0]) capcnt1[7] <= 1'b0; else capcnt0[7] <= 1'b0;
                    st <= S_STORE;
                end
            end

            // write the buffered capture words (melonDS SPUCaptureUnit::FIFO_FlushData)
            S_CFL: begin
                cfl_rdy <= 1'b1;
                if (cfl_k == cfl_n) begin
                    st <= S_CAPA;
                    if (cap_wrap && ccnt[2]) begin
                        if (ent[0]) capcnt1[7] <= 1'b0; else capcnt0[7] <= 1'b0;
                        st <= S_STORE;
                    end
                end else if (cfl_go) begin
                    cfl_k <= cfl_k + 3'd1;
                    cfl_rdy <= 1'b0;
                end
            end

            S_STORE: begin
                cnt <= 4'd0;
                if (!WORKER_READ_ONLY && ent[4]) begin
                    ent <= EVENT_MODE && EVENT_FAST ? fast_next(ent+5'd1,event_mask) : ent + 5'd1;
                    // The last capture row commits on this edge. Without an
                    // output/selection pass the following end sentinel has
                    // no work; dispatch the next ordered event a cycle sooner.
                    if(EVENT_MODE && EVENT_FAST && MULTI_PARENT && !event_output && !selpass &&
                       fast_next(ent+5'd1,event_mask)==5'd18)begin
                        st<=S_IDLE;win<=0;
                    end else st<=S_BOUND;
                end
                else st <= S_MIX;
            end

            S_MIX: begin
                cnt <= cnt + 4'd1;
                if ((EVENT_MODE && EVENT_FAST) || cnt == 4'd4) begin
                    cnt <= 4'd0;
                    ent <= EVENT_MODE && EVENT_FAST && !selpass ? fast_next(ent+5'd1,event_mask) : ent + (selpass ? 5'd2 : 5'd1);
                    // A worker has no capture/output second pass. Its final
                    // contribution commits on this edge, so the otherwise
                    // empty sentinel S_BOUND need not delay worker_ready.
                    // Parent/serial output and register ordering keep S_BOUND.
                    if(EVENT_MODE && EVENT_FAST && WORKER_ID>=0 && !selpass &&
                       fast_next(ent+5'd1,event_mask)==5'd18)begin
                        st<=S_IDLE;win<=0;
                    end else st <= S_BOUND;
                end
            end

            // master volume, bias, clamp (melonDS SPU::Mix)
            S_OUT: begin
                cnt <= cnt + 4'd1;
                if (cnt == 4'd2) begin
                    out_valid <= 1'b1;
                    win <= 1'b0;
                    selpass <= 1'b0;
                    st <= S_IDLE;
                end
            end

            default: st <= S_IDLE;
        endcase

        engine_late <= EVENT_MODE ? (event_overflow || (tick && event_outputs_pending!=0)) : tick && (win || tick_pend);
        if (tick && !EVENT_MODE) begin
            tick_pend <= 1'b1;
            if (win || tick_pend) engine_overrun <= 1'b1;
        end

        if(EVENT_MODE && (event_overflow || (tick && event_outputs_pending!=0)))engine_overrun<=1;
        if (rst) begin
            st <= S_CLEAR; clr <= 8'd0; cpu_read <= 0; event_mask<=0;event_work_due<=0;event_output<=0; tick_pend <= 1'b0; engine_overrun <= 1'b0; win <= 1'b0;
            soundcnt <= '0; bias <= '0; capcnt0 <= '0; capcnt1 <= '0; cap_start <= '0;
            busy <= '0; keyon <= '0; selpass <= 1'b0;
            ent <= '0; cnt <= '0;
        end
    end

    // (no reset: the outputs matter only with out_valid)
    always_ff @(posedge clk) if (ce) begin
        if (st == S_OUT && cnt == 4'd1) out_l <= mclamp & {16{power}};
        if (st == S_OUT && cnt == 4'd2) out_r <= mclamp & {16{power}};
    end
    assign dac_l = {~out_l[15], out_l[14:6]};
    assign dac_r = {~out_r[15], out_r[14:6]};

    // ------------------------------------------------------------ fetcher
    // Serves the queue one entry at a time, from the queue RAM's output:
    // a refill burst, or one capture word.
    typedef enum logic [1:0] { F_IDLE, F_HEAD, F_RUN } fstate_t;
    fstate_t     fs;
    logic [3:0]  q_wp, q_rp;
    logic [2:0]  c_iss, c_rcv;
    logic        quad_pending;
    logic [1:0]  quad_beat;
    logic        h_we, h_zero;
    logic [31:0] h_data;
    logic [3:0]  h_ch;
    logic [24:0] h_addr;
    logic [2:0]  h_n, h_wp;
    logic [1:0]  h_lap;
    assign {h_we, h_data, h_ch, h_addr, h_zero, h_n, h_wp, h_lap} = q_q;

    assign q_wa = q_wp;
    assign q_ra = q_rp;
    assign q_wd = {MULTI_PARENT ? 1'b1 : WORKER_READ_ONLY ? 1'b0 : ent[4], cb_q, ent[3:0], faddr[24:0], faddr[25:12] == 14'd0 && !ent[4], burst, f_wp, f_wlap};

    logic [3:0] c_wsum;
    assign c_wsum = {1'b0, h_wp} + {1'b0, c_rcv};
    assign ff_wa = {h_ch, c_wsum[2:0]};
    assign ff_wd = h_zero ? 32'd0 : engine_mem_rdata;
    // Physical quad beats include the aligned block's leading words. They
    // still consume owner credits, but only requested words enter the FIFO.
    wire quad_keep = !MEM_QUAD || !quad_pending || quad_beat>=h_addr[1:0];
    assign ff_we = !MULTI_PARENT && (fs == F_RUN) && !h_we && (h_zero || (engine_mem_rvalid && quad_keep));
    assign tg_we = !MULTI_PARENT && (ff_we || st == S_RETAG);
    assign tg_wa = ff_we ? ff_wa : {ent[3:0], cnt[2:0]};
    assign tg_wd = ff_we ? h_lap + {1'b0, c_wsum[3]} : f_wlap - 2'd1;

    assign engine_mem_req = (fs == F_RUN) && !h_zero && c_iss != h_n && (!MEM_QUAD || !quad_pending);
    assign engine_mem_we = !WORKER_READ_ONLY && h_we;
    // Read the existing aligned MAIN packet containing the logical refill's
    // first word. Retain its suffix, then issue the finite remainder scalar.
    // Short refills, other regions and capture writes stay scalar. No packet
    // is retained for reuse on a later loop.
    assign engine_mem_n4 = MEM_QUAD && fs==F_RUN && !h_we && h_n==4 && c_iss==0 && h_addr[24:22]==3'd2;
    assign engine_mem_addr = engine_mem_n4 ? {h_addr[24:2],2'b00} : h_addr + {22'b0, c_iss};
    assign engine_mem_wdata = WORKER_READ_ONLY ? 32'd0 : h_data;
    assign q_pop = (fs == F_RUN) && (h_we ? engine_mem_ack : ff_we && (c_rcv + 3'd1 == h_n));
    assign q_we = (fill_go && burst != 3'd0) || cfl_go;

`ifndef ALTERA_RESERVED_QIS
`ifndef SYNTHESIS
    always_ff @(posedge clk) if(ce && !rst) begin
        assert(q_cnt<=16 && 4'(q_wp-q_rp)==4'(q_cnt))
            else $fatal(1,"sound fetch queue pointer/count invariant");
        if(q_we && q_wa==q_ra)assert(q_cnt==0)
            else $fatal(1,"sound fetch queue nonempty read/write collision");
        if(fs==F_RUN)assert(q_cnt!=0 && !q_collision_q)
            else $fatal(1,"sound fetch queue collision/empty head consumed");
    end
`endif
    always_ff @(posedge clk)if(ce && !rst && MEM_QUAD)begin
        if(quad_pending && (fs!=F_RUN || h_we || h_n!=4 || h_addr[24:22]!=3'd2))
            $fatal(1,"sound quad context released before physical drain");
        if(quad_pending && engine_mem_req)
            $fatal(1,"sound descriptor issued before physical quad drain");
        if(q_pop && quad_pending && quad_beat!=3)
            $fatal(1,"sound quad completed before fourth physical beat");
        if(q_pop && !h_we && !h_zero && c_iss!=h_n)
            $fatal(1,"sound logical refill completed before all words issued");
    end
`endif

    always_ff @(posedge clk) if (ce) begin
        case (fs)
            F_IDLE: if (q_cnt != 5'd0) fs <= F_HEAD;
            F_HEAD: begin                   // the queue RAM output follows q_rp
                c_iss <= 3'd0; c_rcv <= 3'd0;
                fs <= F_RUN;
            end
            F_RUN: begin
                if (engine_mem_req && engine_mem_ack) c_iss <= c_iss + (engine_mem_n4 ? 3'd4-{1'b0,h_addr[1:0]} : 3'd1);
                if (ff_we) c_rcv <= c_rcv + 3'd1;
                if (q_pop) fs <= F_IDLE;
            end
            default: fs <= F_IDLE;
        endcase
        if(engine_mem_req && engine_mem_ack && engine_mem_n4)begin quad_pending<=1;quad_beat<=0;end
        if(quad_pending && engine_mem_rvalid)begin
            if(quad_beat==3)quad_pending<=0;else quad_beat<=quad_beat+1'b1;
        end
        if (q_we) q_wp <= q_wp + 4'd1;
        if (q_pop) q_rp <= q_rp + 4'd1;
        q_cnt <= q_cnt + {4'b0, q_we} - {4'b0, q_pop};
        if (rst) begin
            fs <= F_IDLE; q_wp <= '0; q_rp <= '0; q_cnt <= '0;
            quad_pending<=0;quad_beat<=0;
        end
    end
