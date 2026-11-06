`timescale 1ns/1ps
// Sound engine equivalence: rtl/sound against an earlier revision (old_sound,
// renamed by snd_eq.sh), side by side on random ARM7 register traffic, ticks
// and memory latency, every output compared every cycle. Both engines see
// the same acks and read data, driven from the new one's requests, so the
// first difference in a request is reported where it happens.
module tb_whole_pipe #(parameter bit EM=1, EF=1, MQ=1, parameter integer EW=4, parameter bit CUT=1, parameter integer FMT=-1, TMR=32, parameter bit ZERO=0, PIPED=1, PMIX=1);
    logic clk = 0, clk_2x = 1, rst = 1, ce = 1, tick = 0;
    logic        reg_req = 0, reg_we = 0;
    logic [1:0]  reg_size = 2;
    logic [8:0]  reg_addr = 0;
    logic [31:0] reg_wdata = 0;
    logic        mem_ack = 0, mem_rvalid = 0;
    logic [31:0] mem_rdata = 0;
    logic n_n4,o_n4;
    logic [4:0] n_active,o_active,n_updates,o_updates;
    logic        n_reg_ack, o_reg_ack, n_mem_req, o_mem_req, n_mem_we, o_mem_we;
    logic [31:0] n_reg_rdata, o_reg_rdata, n_mem_wdata, o_mem_wdata;
    logic [24:0] n_mem_addr, o_mem_addr;
    logic        n_out_valid, o_out_valid, n_overrun, o_overrun, n_late, o_late;
    logic [15:0] n_out_l, o_out_l, n_out_r, o_out_r;
    logic [9:0]  n_dac_l, o_dac_l, n_dac_r, o_dac_r;
    sound #(.PARENT_MIX_PIPE(PMIX),.WORKER_PIPE(PIPED),.WORKER_CAPTURE_CUT(CUT),.EVENT_MODE(EM),.EVENT_FAST(EF),.EVENT_WORKERS(EW),.MEM_QUAD(MQ),.TIMER_DIV(4)) u_new (.clk, .clk_2x, .ce, .rst, .tick, .power(1'b1), .reg_req, .reg_we, .reg_size, .reg_addr, .reg_wdata,
        .reg_ack(n_reg_ack), .reg_rdata(n_reg_rdata), .mem_req(n_mem_req), .mem_we(n_mem_we), .mem_n4(n_n4), .service_active(n_active), .service_updates(n_updates), .worker_kick(1'b0), .worker_due_mask(18'd0), .worker_refresh_mask(18'd0), .mem_addr(n_mem_addr),
        .mem_wdata(n_mem_wdata), .mem_ack, .mem_rvalid, .mem_rdata, .out_valid(n_out_valid), .out_l(n_out_l),
        .out_r(n_out_r), .dac_l(n_dac_l), .dac_r(n_dac_r), .overrun(n_overrun), .late(n_late));
    old_sound #(
`ifdef OLD_PIPE_REFERENCE
 .WORKER_PIPE(1),
`endif
.EVENT_MODE(EM),.EVENT_FAST(EF),.EVENT_WORKERS(EW),.MEM_QUAD(MQ),.TIMER_DIV(4)) u_old (.clk,
`ifdef OLD_PIPE_REFERENCE
 .clk_2x,
`endif
 .ce, .rst, .tick, .power(1'b1), .reg_req, .reg_we, .reg_size, .reg_addr, .reg_wdata,
        .reg_ack(o_reg_ack), .reg_rdata(o_reg_rdata), .mem_req(o_mem_req), .mem_we(o_mem_we), .mem_n4(o_n4), .service_active(o_active), .service_updates(o_updates), .worker_kick(1'b0), .worker_due_mask(18'd0), .worker_refresh_mask(18'd0), .mem_addr(o_mem_addr),
        .mem_wdata(o_mem_wdata), .mem_ack, .mem_rvalid, .mem_rdata, .out_valid(o_out_valid), .out_l(o_out_l),
        .out_r(o_out_r), .dac_l(o_dac_l), .dac_r(o_dac_r), .overrun(o_overrun), .late(o_late));

    int fmt=FMT,tmr=TMR;bit zero=ZERO,align_once=0,align_done=0;int max_pipe_heads=0,aligned_decode_edges=0,parent_pipe_edges=0,parent_pipe_memory_overlap=0;
    int unsigned seed = 1, cycles = 2000000, half = 0;
    longint bad = 0, n_itc = 0, n_out = 0, n_rd = 0;logic[31:0]parent_rows=0;
    logic [24:0] rq [$];
    always #2 clk = ~clk;
    always #1 clk_2x = ~clk_2x;
    always @(posedge clk)begin #0.1;if(half)ce=!ce;end

    function automatic logic [31:0] h32(input logic [31:0] x);
        x = x ^ (x >> 16); x = x * 32'h7feb352d; x = x ^ (x >> 15); x = x * 32'h846ca68b; return x ^ (x >> 16);
    endfunction
    function automatic logic [31:0] rnd_reg(input logic [8:0] a);
        logic [31:0] v = $urandom;
        case (a[3:2])
            2'd0: begin                     // SOUNDxCNT: formats 0-3, repeat modes, start often
                v[31] = ($urandom % 3) != 0; v[28:27] = $urandom % 4; v[30:29] = ($urandom % 2) ? 2'd2 : $urandom % 4;
            end
            2'd1: v = {7'd0, 6'($urandom), 17'($urandom), 2'd0};   // SAD in a small window
            2'd2: v = {$urandom % 16'd24, 16'hF000 | 16'($urandom)};   // PNT small, fast timer
            default: v = ($urandom % 8 == 0) ? 32'd0 : ($urandom % 8 == 0) ? $urandom % (1 << 21) : $urandom % 512;   // LEN: sometimes 0 or full width
        endcase
        if (a == 9'h114 || a == 9'h11C) v = ($urandom % 4 == 0) ? 32'd0 : $urandom % 64;   // capture LEN: 0 is one word
        return v;
    endfunction

    initial begin
        void'($value$plusargs("seed=%d", seed));
        void'($value$plusargs("cycles=%d", cycles));
        void'($value$plusargs("half=%d", half));
        void'($value$plusargs("fmt=%d", fmt));void'($value$plusargs("timer=%d",tmr));
        void'($value$plusargs("zero=%d",zero));void'($value$plusargs("align=%d",align_once));
        void'($urandom(seed));
        repeat (4) @(negedge clk);
        rst = 0;
    end

    int unsigned cyc = 0, tcnt = 0, gap = 0, setup_index = 0;
    always @(negedge clk) begin
        cyc++;
        if(PIPED && $countones(u_new.g_workers.pipe_request_v)>max_pipe_heads)max_pipe_heads=$countones(u_new.g_workers.pipe_request_v);
        if($countones(n_updates[3:0])==4)aligned_decode_edges++;
        if(u_new.g_workers.pipe_request_v[4])begin
            parent_pipe_edges++;
            if(|u_new.g_workers.req[3:0])parent_pipe_memory_overlap++;
        end
        if(align_once && !align_done && setup_index==86 && (&u_old.worker_idle) && ce && !rst)begin
            // Directed legal timer state on both sides; no phase target is inferred.
            for(int t=0;t<18;t++)begin
                u_new.g_event_timers.bank.timer[t]=16'hffff;
                u_old.g_event_timers.bank.timer[t]=16'hffff;
            end
            align_done=1;
        end
        // outputs, compared before every edge
        if (!rst && (n_reg_ack !== o_reg_ack || (n_reg_ack && n_reg_rdata !== o_reg_rdata) ||
            n_mem_req !== o_mem_req || (n_mem_req && (n_mem_we !== o_mem_we || n_n4 !== o_n4 || n_mem_addr !== o_mem_addr ||
            (n_mem_we && n_mem_wdata !== o_mem_wdata))) || n_out_valid !== o_out_valid || n_out_l !== o_out_l ||
            n_out_r !== o_out_r || n_dac_l !== o_dac_l || n_dac_r !== o_dac_r || n_overrun !== o_overrun || n_late !== o_late || n_active !== o_active || n_updates !== o_updates ||
            u_new.st !== u_old.st || u_new.ent !== u_old.ent || u_new.event_count !== u_old.event_count ||
            u_new.event_wp !== u_old.event_wp || u_new.event_rp !== u_old.event_rp ||
            u_new.event_head_valid !== u_old.event_head_valid || u_new.event_pop !== u_old.event_pop ||
            u_new.event_outputs_pending !== u_old.event_outputs_pending ||
            (u_new.event_head_valid && u_new.event_head !== u_old.event_head))) begin
            bad++;
            if (bad <= 5) $display("cycle %0d: new ack %b rd %h req %b we %b a %h out %b %h %h | old ack %b rd %h req %b we %b a %h out %b %h %h",
                cyc, n_reg_ack, n_reg_rdata, n_mem_req, n_mem_we, n_mem_addr, n_out_valid, n_out_l, n_out_r,
                o_reg_ack, o_reg_rdata, o_mem_req, o_mem_we, o_mem_addr, o_out_valid, o_out_l, o_out_r);
        end
        if (ce)begin n_itc += $countones(n_updates);if(u_new.st==u_new.S_LOAD)parent_rows[u_new.ent]=1;end
        if (bad) $fatal(1,"cycle differential mismatch at %0d",cyc);
        if (n_out_valid && ce) n_out++;
        if (cyc >= cycles) begin
            if(setup_index<86 || n_out<10 || ((fmt<0 || fmt==2) && n_itc<10) || n_rd<10)$fatal(1,"insufficient exercised service");
            if (bad) $display("DIFFER:"); else $display("EQUIVALENT:");
            $display("PARENT_ROW_READ_MASK %h",parent_rows);
            $display("PARENT_PIPE_COVER jobs_edges=%0d concurrent_voice_memory=%0d",parent_pipe_edges,parent_pipe_memory_overlap);
            $display("PIPE_BURST_COVER heads=%0d aligned_decode_edges=%0d directed_timer_state=%0d fmt=%0d zero=%0d",max_pipe_heads,aligned_decode_edges,align_done,fmt,zero);
            if(align_once && !align_done)$fatal(1,"directed alignment state not reached");
            $display(": %0d cycles, %0d differing (seed %0d, half %0d): %0d output steps, %0d ADPCM decodes, %0d memory reads",
                cycles, bad, seed, half, n_out, n_itc, n_rd);
            $finish;
        end
        // half: the engine's ce every other clk; the stimulus changes only on ce edges
        // CE changes after SYS E, never at the coincident FAST M edge.
        if (!half || ce) begin
            // memory: an ack per request edge at random, reads answer in order 0-12 edges later
            mem_ack = n_mem_req && ($urandom % 4 != 0);   // taken at the next edge
            // Only previously accepted requests may return on this edge.
            mem_rvalid = 0;
            if (rq.size() != 0 && ($urandom % 3 == 0)) begin mem_rvalid = 1; mem_rdata = h32({7'd0, rq.pop_front()} ^ seed); end
            if (mem_ack && !n_mem_we) begin
                for(int k=0;k<(n_n4?4:1);k++)begin rq.push_back(n_mem_addr+25'(k));n_rd++;end
            end
            // ticks: one per 1,024 engine clocks
            tick = 0;
            if (++tcnt == 2048) begin tcnt = 0; tick = 1; end
            // registers: one access at a time, held until acked
            if (reg_req && n_reg_ack) begin reg_req = 0; gap = $urandom % 600; end
            else if (!reg_req && !rst) begin
                if (gap != 0) gap--;
                else begin
                    reg_req = 1; reg_we = ($urandom % 5) != 0;
                    if ($urandom % 12 == 0) reg_addr = 9'h100 + 9'(($urandom % 8) * 4);   // SOUNDCNT, bias, capture
                    else reg_addr = {1'b0, 4'($urandom), 2'($urandom), 2'b00};
                    reg_size = 2; reg_wdata = reg_addr[8] ? $urandom : rnd_reg(reg_addr);
                    if (reg_addr == 9'h100) reg_wdata[15] = 1'b1;         // master enable
                    if ($urandom % 6 == 0) begin                         // 8/16-bit writes
                        reg_size = $urandom % 2; reg_addr[1:0] = reg_size ? {$urandom % 2, 1'b0} : 2'($urandom);
                    end
                    if(setup_index<85)begin
                        reg_req=1;reg_we=1;reg_size=2;
                        if(setup_index<80)begin
                            reg_addr=9'((setup_index/5)*16);
                            case(setup_index%5)
                                0:begin reg_addr+=4;reg_wdata=(zero?32'd0:32'h02001000)+32'((setup_index/5)*128);end
                                1:begin reg_addr+=8;reg_wdata=32'h00010000 | 32'(16'(-tmr));end
                                2:begin reg_addr+=12;reg_wdata=8;end
                                3:begin reg_wdata=0;end
                                4:begin reg_wdata=32'h8800007f | (32'(fmt<0?(setup_index/5)%4:fmt)<<29) | (32'((setup_index/5)*8)<<16);end
                            endcase
                        end else case(setup_index)
                            80:begin reg_addr=9'h100;reg_wdata=32'h8000;end
                            81:begin reg_addr=9'h110;reg_wdata=32'h02010000;end
                            82:begin reg_addr=9'h114;reg_wdata=64;end
                            83:begin reg_addr=9'h118;reg_wdata=32'h02011000;end
                            84:begin reg_addr=9'h11c;reg_wdata=64;end
                        endcase
                        setup_index++;
                    end else if(setup_index==85)begin
                        reg_req=1;reg_we=1;reg_size=1;reg_addr=9'h108;reg_wdata=32'h00008080;setup_index++;
                    end
                end
            end
        end
    end

    always @(negedge clk)if(!rst)begin
        assert(u_new.g_workers.selected===u_old.g_workers.selected && u_new.g_workers.found===u_old.g_workers.found)
            else $fatal(1,"parent selector mismatch");
        assert(u_new.g_workers.pointer===u_old.g_workers.pointer && u_new.g_workers.held===u_old.g_workers.held &&
               u_new.g_workers.hold_valid===u_old.g_workers.hold_valid && u_new.g_workers.response_count===u_old.g_workers.response_count)
            else $fatal(1,"parent control state mismatch");
    end
    always @(negedge clk)if(!rst)begin
        assert({u_new.w0,u_new.w1,u_new.w2,u_new.w3,u_new.w4,u_new.w5,u_new.w6,u_new.w7,u_new.w5p}===
               {u_old.w0,u_old.w1,u_old.w2,u_old.w3,u_old.w4,u_old.w5,u_old.w6,u_old.w7,u_old.w5p})else $fatal(1,"working state mismatch");
        assert({u_new.runtime_sample1,u_new.runtime_sample3}==={u_old.runtime_sample1,u_old.runtime_sample3})else $fatal(1,"fixed taps mismatch");
        if(ce && u_new.st==u_new.S_LOAD)begin
            for(int w=0;w<4;w++)assert(u_new.config_row[w]===u_old.config_row[w])else $fatal(1,"load config mismatch");
            assert(u_new.runtime_row===u_old.runtime_row && u_new.rr_q===u_old.rr_q)else $fatal(1,"load runtime mismatch");
        end
        for(int a=0;a<128;a++)assert(u_new.u_cpu.mem[a]===u_old.u_cpu.mem[a])else $fatal(1,"CPU mirror mismatch");
        for(int a=0;a<32;a++)assert(u_new.u_run.mem[a]===u_old.u_run.mem[a])else $fatal(1,"runtime mirror mismatch");
    end
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_config.g_word[0].g_byte[0].u_bank.mem[slot]===u_old.g_parent_config.g_word[0].g_byte[0].u_bank.mem[slot])else $fatal(1,"config storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_config.g_word[0].g_byte[1].u_bank.mem[slot]===u_old.g_parent_config.g_word[0].g_byte[1].u_bank.mem[slot])else $fatal(1,"config storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_config.g_word[0].g_byte[2].u_bank.mem[slot]===u_old.g_parent_config.g_word[0].g_byte[2].u_bank.mem[slot])else $fatal(1,"config storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_config.g_word[0].g_byte[3].u_bank.mem[slot]===u_old.g_parent_config.g_word[0].g_byte[3].u_bank.mem[slot])else $fatal(1,"config storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_config.g_word[1].g_byte[0].u_bank.mem[slot]===u_old.g_parent_config.g_word[1].g_byte[0].u_bank.mem[slot])else $fatal(1,"config storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_config.g_word[1].g_byte[1].u_bank.mem[slot]===u_old.g_parent_config.g_word[1].g_byte[1].u_bank.mem[slot])else $fatal(1,"config storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_config.g_word[1].g_byte[2].u_bank.mem[slot]===u_old.g_parent_config.g_word[1].g_byte[2].u_bank.mem[slot])else $fatal(1,"config storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_config.g_word[1].g_byte[3].u_bank.mem[slot]===u_old.g_parent_config.g_word[1].g_byte[3].u_bank.mem[slot])else $fatal(1,"config storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_config.g_word[2].g_byte[0].u_bank.mem[slot]===u_old.g_parent_config.g_word[2].g_byte[0].u_bank.mem[slot])else $fatal(1,"config storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_config.g_word[2].g_byte[1].u_bank.mem[slot]===u_old.g_parent_config.g_word[2].g_byte[1].u_bank.mem[slot])else $fatal(1,"config storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_config.g_word[2].g_byte[2].u_bank.mem[slot]===u_old.g_parent_config.g_word[2].g_byte[2].u_bank.mem[slot])else $fatal(1,"config storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_config.g_word[2].g_byte[3].u_bank.mem[slot]===u_old.g_parent_config.g_word[2].g_byte[3].u_bank.mem[slot])else $fatal(1,"config storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_config.g_word[3].g_byte[0].u_bank.mem[slot]===u_old.g_parent_config.g_word[3].g_byte[0].u_bank.mem[slot])else $fatal(1,"config storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_config.g_word[3].g_byte[1].u_bank.mem[slot]===u_old.g_parent_config.g_word[3].g_byte[1].u_bank.mem[slot])else $fatal(1,"config storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_config.g_word[3].g_byte[2].u_bank.mem[slot]===u_old.g_parent_config.g_word[3].g_byte[2].u_bank.mem[slot])else $fatal(1,"config storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_config.g_word[3].g_byte[3].u_bank.mem[slot]===u_old.g_parent_config.g_word[3].g_byte[3].u_bank.mem[slot])else $fatal(1,"config storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_runtime.g_byte[0].u_bank.mem[slot]===u_old.g_parent_runtime.g_byte[0].u_bank.mem[slot])else $fatal(1,"runtime storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_runtime.g_byte[1].u_bank.mem[slot]===u_old.g_parent_runtime.g_byte[1].u_bank.mem[slot])else $fatal(1,"runtime storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_runtime.g_byte[2].u_bank.mem[slot]===u_old.g_parent_runtime.g_byte[2].u_bank.mem[slot])else $fatal(1,"runtime storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_runtime.g_byte[3].u_bank.mem[slot]===u_old.g_parent_runtime.g_byte[3].u_bank.mem[slot])else $fatal(1,"runtime storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_runtime.g_byte[4].u_bank.mem[slot]===u_old.g_parent_runtime.g_byte[4].u_bank.mem[slot])else $fatal(1,"runtime storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_runtime.g_byte[5].u_bank.mem[slot]===u_old.g_parent_runtime.g_byte[5].u_bank.mem[slot])else $fatal(1,"runtime storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_runtime.g_byte[6].u_bank.mem[slot]===u_old.g_parent_runtime.g_byte[6].u_bank.mem[slot])else $fatal(1,"runtime storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_runtime.g_byte[7].u_bank.mem[slot]===u_old.g_parent_runtime.g_byte[7].u_bank.mem[slot])else $fatal(1,"runtime storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_runtime.g_byte[8].u_bank.mem[slot]===u_old.g_parent_runtime.g_byte[8].u_bank.mem[slot])else $fatal(1,"runtime storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_runtime.g_byte[9].u_bank.mem[slot]===u_old.g_parent_runtime.g_byte[9].u_bank.mem[slot])else $fatal(1,"runtime storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_runtime.g_byte[10].u_bank.mem[slot]===u_old.g_parent_runtime.g_byte[10].u_bank.mem[slot])else $fatal(1,"runtime storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_runtime.g_byte[11].u_bank.mem[slot]===u_old.g_parent_runtime.g_byte[11].u_bank.mem[slot])else $fatal(1,"runtime storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_runtime.g_byte[12].u_bank.mem[slot]===u_old.g_parent_runtime.g_byte[12].u_bank.mem[slot])else $fatal(1,"runtime storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_runtime.g_byte[13].u_bank.mem[slot]===u_old.g_parent_runtime.g_byte[13].u_bank.mem[slot])else $fatal(1,"runtime storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_runtime.g_byte[14].u_bank.mem[slot]===u_old.g_parent_runtime.g_byte[14].u_bank.mem[slot])else $fatal(1,"runtime storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_runtime.g_byte[15].u_bank.mem[slot]===u_old.g_parent_runtime.g_byte[15].u_bank.mem[slot])else $fatal(1,"runtime storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_runtime.g_byte[16].u_bank.mem[slot]===u_old.g_parent_runtime.g_byte[16].u_bank.mem[slot])else $fatal(1,"runtime storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_runtime.g_byte[17].u_bank.mem[slot]===u_old.g_parent_runtime.g_byte[17].u_bank.mem[slot])else $fatal(1,"runtime storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_runtime.g_byte[18].u_bank.mem[slot]===u_old.g_parent_runtime.g_byte[18].u_bank.mem[slot])else $fatal(1,"runtime storage mismatch");
    always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_parent_runtime.g_byte[19].u_bank.mem[slot]===u_old.g_parent_runtime.g_byte[19].u_bank.mem[slot])else $fatal(1,"runtime storage mismatch");
    genvar owner;
    generate for(owner=0;owner<4;owner++)begin:compare_owned
        always @(negedge clk)if(!rst)begin
            assert({u_new.g_workers.lane[owner].engine.st,u_new.g_workers.lane[owner].engine.cnt,u_new.g_workers.lane[owner].engine.ent,
                    u_new.g_workers.lane[owner].engine.w0,u_new.g_workers.lane[owner].engine.w1,u_new.g_workers.lane[owner].engine.w2,u_new.g_workers.lane[owner].engine.w3,
                    u_new.g_workers.lane[owner].engine.w4,u_new.g_workers.lane[owner].engine.w5,u_new.g_workers.lane[owner].engine.w6,u_new.g_workers.lane[owner].engine.w7,u_new.g_workers.lane[owner].engine.w5p}===
                   {u_old.g_workers.lane[owner].engine.st,u_old.g_workers.lane[owner].engine.cnt,u_old.g_workers.lane[owner].engine.ent,
                    u_old.g_workers.lane[owner].engine.w0,u_old.g_workers.lane[owner].engine.w1,u_old.g_workers.lane[owner].engine.w2,u_old.g_workers.lane[owner].engine.w3,
                    u_old.g_workers.lane[owner].engine.w4,u_old.g_workers.lane[owner].engine.w5,u_old.g_workers.lane[owner].engine.w6,u_old.g_workers.lane[owner].engine.w7,u_old.g_workers.lane[owner].engine.w5p})else $fatal(1,"worker working/state mismatch owner%0d",owner);
            // Shared arithmetic is compared on its actual consumer edge by g_pipe_head.

            assert({u_new.g_workers.lane[owner].engine.event_count,u_new.g_workers.lane[owner].engine.event_wp,u_new.g_workers.lane[owner].engine.event_rp,u_new.g_workers.lane[owner].engine.event_head_valid,
                    u_new.g_workers.lane[owner].engine.event_pop,u_new.g_workers.lane[owner].engine.event_accept,u_new.g_workers.lane[owner].engine.event_mask,u_new.g_workers.lane[owner].engine.fs,u_new.g_workers.lane[owner].engine.q_cnt}===
                   {u_old.g_workers.lane[owner].engine.event_count,u_old.g_workers.lane[owner].engine.event_wp,u_old.g_workers.lane[owner].engine.event_rp,u_old.g_workers.lane[owner].engine.event_head_valid,
                    u_old.g_workers.lane[owner].engine.event_pop,u_old.g_workers.lane[owner].engine.event_accept,u_old.g_workers.lane[owner].engine.event_mask,u_old.g_workers.lane[owner].engine.fs,u_old.g_workers.lane[owner].engine.q_cnt})else $fatal(1,"worker event/fetch edge mismatch owner%0d",owner);
            if(u_new.g_workers.lane[owner].engine.event_head_valid)assert(u_new.g_workers.lane[owner].engine.event_head===u_old.g_workers.lane[owner].engine.event_head)else $fatal(1,"worker queued event mismatch");
            for(int a=0;a<128;a++)assert(u_new.g_workers.lane[owner].engine.u_cpu.mem[a]===u_old.g_workers.lane[owner].engine.u_cpu.mem[a] &&
                u_new.g_workers.lane[owner].engine.u_fifo.mem[a]===u_old.g_workers.lane[owner].engine.u_fifo.mem[a] &&
                u_new.g_workers.lane[owner].engine.u_tag.mem[a]===u_old.g_workers.lane[owner].engine.u_tag.mem[a])else $fatal(1,"worker CPU/FIFO/tag mismatch");
            for(int a=0;a<32;a++)assert(u_new.g_workers.lane[owner].engine.u_run.mem[a]===u_old.g_workers.lane[owner].engine.u_run.mem[a])else $fatal(1,"worker runtime mirror mismatch");
            if(ce && u_new.g_workers.lane[owner].engine.st==u_new.g_workers.lane[owner].engine.S_LOAD)begin
                for(int w=0;w<4;w++)assert(u_new.g_workers.lane[owner].engine.config_row[w]===u_old.g_workers.lane[owner].engine.config_row[w])else $fatal(1,"worker registered config load mismatch");
                assert(u_new.g_workers.lane[owner].engine.runtime_row===u_old.g_workers.lane[owner].engine.runtime_row)else $fatal(1,"worker registered runtime load mismatch");
            end
            assert({u_new.g_workers.lane[owner].engine.f_idxl,u_new.g_workers.lane[owner].engine.f_vall}===
                   {u_old.g_workers.lane[owner].engine.f_idxl,u_old.g_workers.lane[owner].engine.f_vall})else $fatal(1,"worker live loop state mismatch");
            for(int slot=0;slot<4;slot++)begin
                assert(u_new.g_workers.lane[owner].engine.event_left[slot]===u_old.g_workers.lane[owner].engine.event_left[slot] &&
                       u_new.g_workers.lane[owner].engine.event_right[slot]===u_old.g_workers.lane[owner].engine.event_right[slot])else $fatal(1,"owned contribution mismatch owner%0d slot%0d",owner,slot);
            end
            assert(u_new.g_workers.lane[owner].engine.worker_left===u_old.g_workers.lane[owner].engine.worker_left&&
                   u_new.g_workers.lane[owner].engine.worker_right===u_old.g_workers.lane[owner].engine.worker_right&&
                   u_new.g_workers.lane[owner].engine.worker_stop===u_old.g_workers.lane[owner].engine.worker_stop&&
                   u_new.g_workers.lane[owner].engine.worker_sample1===u_old.g_workers.lane[owner].engine.worker_sample1&&
                   u_new.g_workers.lane[owner].engine.worker_sample3===u_old.g_workers.lane[owner].engine.worker_sample3)else $fatal(1,"worker sum/stop/sample tap mismatch");
        end
    end endgenerate


    longint push0=0,pop0=0,collision0=0,full0=0,mix0=0,cap0=0;int maxq0=0;
    always @(negedge clk)if(!rst)begin
        assert({u_new.fs,u_new.q_cnt,u_new.q_wp,u_new.q_rp,u_new.q_we,u_new.q_pop,u_new.q_wa,u_new.q_ra,u_new.event_due_mask,u_new.event_restart,u_new.event_accept,u_new.event_pop,u_new.st,u_new.cnt,u_new.ent,u_new.cb_we,u_new.cb_be,u_new.cb_wa,u_new.ff_we,u_new.tg_we,u_new.service_active,u_new.service_updates} === {u_old.fs,u_old.q_cnt,u_old.q_wp,u_old.q_rp,u_old.q_we,u_old.q_pop,u_old.q_wa,u_old.q_ra,u_old.event_due_mask,u_old.event_restart,u_old.event_accept,u_old.event_pop,u_old.st,u_old.cnt,u_old.ent,u_old.cb_we,u_old.cb_be,u_old.cb_wa,u_old.ff_we,u_old.tg_we,u_old.service_active,u_old.service_updates})else $fatal(1,"queue causal edge mismatch instance0");
        if(u_new.q_we)assert(u_new.q_wd===u_old.q_wd)else $fatal(1,"queue input mismatch instance0");
        if(u_new.fs==u_new.F_RUN)assert(u_new.q_q===u_old.q_q)else $fatal(1,"queue consumed head mismatch instance0");
        for(int j=0;j<16;j++)assert(u_new.u_queue.mem[j]===u_old.u_queue.mem[j])else $fatal(1,"queue storage mismatch instance0");
        if(u_new.cb_we)assert(u_new.cb_wd===u_old.cb_wd)else $fatal(1,"capture write sample mismatch instance0");
        if(u_new.ff_we)assert({u_new.ff_wa,u_new.ff_wd}==={u_old.ff_wa,u_old.ff_wd})else $fatal(1,"refill sample mismatch instance0");
        if(ce)begin
          push0+=u_new.q_we;pop0+=u_new.q_pop;collision0+=u_new.q_we&&u_new.q_wa==u_new.q_ra;
          full0+=(u_new.q_cnt==16);mix0+=(u_new.st==u_new.S_MIX);cap0+=u_new.cb_we;
          if(u_new.q_cnt>maxq0)maxq0=u_new.q_cnt;
        end
    end
    final $display("QUEUE_COVER instance0 push=%0d pop=%0d empty_collision=%0d full=%0d max=%0d mix=%0d capbytes=%0d",push0,pop0,collision0,full0,maxq0,mix0,cap0);
    always @(negedge clk) begin
    end

    longint push1=0,pop1=0,collision1=0,full1=0,mix1=0,cap1=0;int maxq1=0;
    always @(negedge clk)if(!rst)begin
        assert({u_new.g_workers.lane[0].engine.fs,u_new.g_workers.lane[0].engine.q_cnt,u_new.g_workers.lane[0].engine.q_wp,u_new.g_workers.lane[0].engine.q_rp,u_new.g_workers.lane[0].engine.q_we,u_new.g_workers.lane[0].engine.q_pop,u_new.g_workers.lane[0].engine.q_wa,u_new.g_workers.lane[0].engine.q_ra,u_new.g_workers.lane[0].engine.event_due_mask,u_new.g_workers.lane[0].engine.event_restart,u_new.g_workers.lane[0].engine.event_accept,u_new.g_workers.lane[0].engine.event_pop,u_new.g_workers.lane[0].engine.st,u_new.g_workers.lane[0].engine.cnt,u_new.g_workers.lane[0].engine.ent,u_new.g_workers.lane[0].engine.cb_we,u_new.g_workers.lane[0].engine.cb_be,u_new.g_workers.lane[0].engine.cb_wa,u_new.g_workers.lane[0].engine.ff_we,u_new.g_workers.lane[0].engine.tg_we,u_new.g_workers.lane[0].engine.service_active,u_new.g_workers.lane[0].engine.service_updates} === {u_old.g_workers.lane[0].engine.fs,u_old.g_workers.lane[0].engine.q_cnt,u_old.g_workers.lane[0].engine.q_wp,u_old.g_workers.lane[0].engine.q_rp,u_old.g_workers.lane[0].engine.q_we,u_old.g_workers.lane[0].engine.q_pop,u_old.g_workers.lane[0].engine.q_wa,u_old.g_workers.lane[0].engine.q_ra,u_old.g_workers.lane[0].engine.event_due_mask,u_old.g_workers.lane[0].engine.event_restart,u_old.g_workers.lane[0].engine.event_accept,u_old.g_workers.lane[0].engine.event_pop,u_old.g_workers.lane[0].engine.st,u_old.g_workers.lane[0].engine.cnt,u_old.g_workers.lane[0].engine.ent,u_old.g_workers.lane[0].engine.cb_we,u_old.g_workers.lane[0].engine.cb_be,u_old.g_workers.lane[0].engine.cb_wa,u_old.g_workers.lane[0].engine.ff_we,u_old.g_workers.lane[0].engine.tg_we,u_old.g_workers.lane[0].engine.service_active,u_old.g_workers.lane[0].engine.service_updates})else $fatal(1,"queue causal edge mismatch instance1");
        if(u_new.g_workers.lane[0].engine.q_we)assert(u_new.g_workers.lane[0].engine.q_wd===u_old.g_workers.lane[0].engine.q_wd)else $fatal(1,"queue input mismatch instance1");
        if(u_new.g_workers.lane[0].engine.fs==u_new.g_workers.lane[0].engine.F_RUN)assert(u_new.g_workers.lane[0].engine.q_q===u_old.g_workers.lane[0].engine.q_q)else $fatal(1,"queue consumed head mismatch instance1");
        for(int j=0;j<16;j++)assert(u_new.g_workers.lane[0].engine.u_queue.mem[j]===u_old.g_workers.lane[0].engine.u_queue.mem[j])else $fatal(1,"queue storage mismatch instance1");
        if(u_new.g_workers.lane[0].engine.cb_we)assert(u_new.g_workers.lane[0].engine.cb_wd===u_old.g_workers.lane[0].engine.cb_wd)else $fatal(1,"capture write sample mismatch instance1");
        if(u_new.g_workers.lane[0].engine.ff_we)assert({u_new.g_workers.lane[0].engine.ff_wa,u_new.g_workers.lane[0].engine.ff_wd}==={u_old.g_workers.lane[0].engine.ff_wa,u_old.g_workers.lane[0].engine.ff_wd})else $fatal(1,"refill sample mismatch instance1");
        if(ce)begin
          push1+=u_new.g_workers.lane[0].engine.q_we;pop1+=u_new.g_workers.lane[0].engine.q_pop;collision1+=u_new.g_workers.lane[0].engine.q_we&&u_new.g_workers.lane[0].engine.q_wa==u_new.g_workers.lane[0].engine.q_ra;
          full1+=(u_new.g_workers.lane[0].engine.q_cnt==16);mix1+=(u_new.g_workers.lane[0].engine.st==u_new.g_workers.lane[0].engine.S_MIX);cap1+=u_new.g_workers.lane[0].engine.cb_we;
          if(u_new.g_workers.lane[0].engine.q_cnt>maxq1)maxq1=u_new.g_workers.lane[0].engine.q_cnt;
        end
    end
    final $display("QUEUE_COVER instance1 push=%0d pop=%0d empty_collision=%0d full=%0d max=%0d mix=%0d capbytes=%0d",push1,pop1,collision1,full1,maxq1,mix1,cap1);
    always @(negedge clk) begin
    end

    longint push2=0,pop2=0,collision2=0,full2=0,mix2=0,cap2=0;int maxq2=0;
    always @(negedge clk)if(!rst)begin
        assert({u_new.g_workers.lane[1].engine.fs,u_new.g_workers.lane[1].engine.q_cnt,u_new.g_workers.lane[1].engine.q_wp,u_new.g_workers.lane[1].engine.q_rp,u_new.g_workers.lane[1].engine.q_we,u_new.g_workers.lane[1].engine.q_pop,u_new.g_workers.lane[1].engine.q_wa,u_new.g_workers.lane[1].engine.q_ra,u_new.g_workers.lane[1].engine.event_due_mask,u_new.g_workers.lane[1].engine.event_restart,u_new.g_workers.lane[1].engine.event_accept,u_new.g_workers.lane[1].engine.event_pop,u_new.g_workers.lane[1].engine.st,u_new.g_workers.lane[1].engine.cnt,u_new.g_workers.lane[1].engine.ent,u_new.g_workers.lane[1].engine.cb_we,u_new.g_workers.lane[1].engine.cb_be,u_new.g_workers.lane[1].engine.cb_wa,u_new.g_workers.lane[1].engine.ff_we,u_new.g_workers.lane[1].engine.tg_we,u_new.g_workers.lane[1].engine.service_active,u_new.g_workers.lane[1].engine.service_updates} === {u_old.g_workers.lane[1].engine.fs,u_old.g_workers.lane[1].engine.q_cnt,u_old.g_workers.lane[1].engine.q_wp,u_old.g_workers.lane[1].engine.q_rp,u_old.g_workers.lane[1].engine.q_we,u_old.g_workers.lane[1].engine.q_pop,u_old.g_workers.lane[1].engine.q_wa,u_old.g_workers.lane[1].engine.q_ra,u_old.g_workers.lane[1].engine.event_due_mask,u_old.g_workers.lane[1].engine.event_restart,u_old.g_workers.lane[1].engine.event_accept,u_old.g_workers.lane[1].engine.event_pop,u_old.g_workers.lane[1].engine.st,u_old.g_workers.lane[1].engine.cnt,u_old.g_workers.lane[1].engine.ent,u_old.g_workers.lane[1].engine.cb_we,u_old.g_workers.lane[1].engine.cb_be,u_old.g_workers.lane[1].engine.cb_wa,u_old.g_workers.lane[1].engine.ff_we,u_old.g_workers.lane[1].engine.tg_we,u_old.g_workers.lane[1].engine.service_active,u_old.g_workers.lane[1].engine.service_updates})else $fatal(1,"queue causal edge mismatch instance2");
        if(u_new.g_workers.lane[1].engine.q_we)assert(u_new.g_workers.lane[1].engine.q_wd===u_old.g_workers.lane[1].engine.q_wd)else $fatal(1,"queue input mismatch instance2");
        if(u_new.g_workers.lane[1].engine.fs==u_new.g_workers.lane[1].engine.F_RUN)assert(u_new.g_workers.lane[1].engine.q_q===u_old.g_workers.lane[1].engine.q_q)else $fatal(1,"queue consumed head mismatch instance2");
        for(int j=0;j<16;j++)assert(u_new.g_workers.lane[1].engine.u_queue.mem[j]===u_old.g_workers.lane[1].engine.u_queue.mem[j])else $fatal(1,"queue storage mismatch instance2");
        if(u_new.g_workers.lane[1].engine.cb_we)assert(u_new.g_workers.lane[1].engine.cb_wd===u_old.g_workers.lane[1].engine.cb_wd)else $fatal(1,"capture write sample mismatch instance2");
        if(u_new.g_workers.lane[1].engine.ff_we)assert({u_new.g_workers.lane[1].engine.ff_wa,u_new.g_workers.lane[1].engine.ff_wd}==={u_old.g_workers.lane[1].engine.ff_wa,u_old.g_workers.lane[1].engine.ff_wd})else $fatal(1,"refill sample mismatch instance2");
        if(ce)begin
          push2+=u_new.g_workers.lane[1].engine.q_we;pop2+=u_new.g_workers.lane[1].engine.q_pop;collision2+=u_new.g_workers.lane[1].engine.q_we&&u_new.g_workers.lane[1].engine.q_wa==u_new.g_workers.lane[1].engine.q_ra;
          full2+=(u_new.g_workers.lane[1].engine.q_cnt==16);mix2+=(u_new.g_workers.lane[1].engine.st==u_new.g_workers.lane[1].engine.S_MIX);cap2+=u_new.g_workers.lane[1].engine.cb_we;
          if(u_new.g_workers.lane[1].engine.q_cnt>maxq2)maxq2=u_new.g_workers.lane[1].engine.q_cnt;
        end
    end
    final $display("QUEUE_COVER instance2 push=%0d pop=%0d empty_collision=%0d full=%0d max=%0d mix=%0d capbytes=%0d",push2,pop2,collision2,full2,maxq2,mix2,cap2);
    always @(negedge clk) begin
    end

    longint push3=0,pop3=0,collision3=0,full3=0,mix3=0,cap3=0;int maxq3=0;
    always @(negedge clk)if(!rst)begin
        assert({u_new.g_workers.lane[2].engine.fs,u_new.g_workers.lane[2].engine.q_cnt,u_new.g_workers.lane[2].engine.q_wp,u_new.g_workers.lane[2].engine.q_rp,u_new.g_workers.lane[2].engine.q_we,u_new.g_workers.lane[2].engine.q_pop,u_new.g_workers.lane[2].engine.q_wa,u_new.g_workers.lane[2].engine.q_ra,u_new.g_workers.lane[2].engine.event_due_mask,u_new.g_workers.lane[2].engine.event_restart,u_new.g_workers.lane[2].engine.event_accept,u_new.g_workers.lane[2].engine.event_pop,u_new.g_workers.lane[2].engine.st,u_new.g_workers.lane[2].engine.cnt,u_new.g_workers.lane[2].engine.ent,u_new.g_workers.lane[2].engine.cb_we,u_new.g_workers.lane[2].engine.cb_be,u_new.g_workers.lane[2].engine.cb_wa,u_new.g_workers.lane[2].engine.ff_we,u_new.g_workers.lane[2].engine.tg_we,u_new.g_workers.lane[2].engine.service_active,u_new.g_workers.lane[2].engine.service_updates} === {u_old.g_workers.lane[2].engine.fs,u_old.g_workers.lane[2].engine.q_cnt,u_old.g_workers.lane[2].engine.q_wp,u_old.g_workers.lane[2].engine.q_rp,u_old.g_workers.lane[2].engine.q_we,u_old.g_workers.lane[2].engine.q_pop,u_old.g_workers.lane[2].engine.q_wa,u_old.g_workers.lane[2].engine.q_ra,u_old.g_workers.lane[2].engine.event_due_mask,u_old.g_workers.lane[2].engine.event_restart,u_old.g_workers.lane[2].engine.event_accept,u_old.g_workers.lane[2].engine.event_pop,u_old.g_workers.lane[2].engine.st,u_old.g_workers.lane[2].engine.cnt,u_old.g_workers.lane[2].engine.ent,u_old.g_workers.lane[2].engine.cb_we,u_old.g_workers.lane[2].engine.cb_be,u_old.g_workers.lane[2].engine.cb_wa,u_old.g_workers.lane[2].engine.ff_we,u_old.g_workers.lane[2].engine.tg_we,u_old.g_workers.lane[2].engine.service_active,u_old.g_workers.lane[2].engine.service_updates})else $fatal(1,"queue causal edge mismatch instance3");
        if(u_new.g_workers.lane[2].engine.q_we)assert(u_new.g_workers.lane[2].engine.q_wd===u_old.g_workers.lane[2].engine.q_wd)else $fatal(1,"queue input mismatch instance3");
        if(u_new.g_workers.lane[2].engine.fs==u_new.g_workers.lane[2].engine.F_RUN)assert(u_new.g_workers.lane[2].engine.q_q===u_old.g_workers.lane[2].engine.q_q)else $fatal(1,"queue consumed head mismatch instance3");
        for(int j=0;j<16;j++)assert(u_new.g_workers.lane[2].engine.u_queue.mem[j]===u_old.g_workers.lane[2].engine.u_queue.mem[j])else $fatal(1,"queue storage mismatch instance3");
        if(u_new.g_workers.lane[2].engine.cb_we)assert(u_new.g_workers.lane[2].engine.cb_wd===u_old.g_workers.lane[2].engine.cb_wd)else $fatal(1,"capture write sample mismatch instance3");
        if(u_new.g_workers.lane[2].engine.ff_we)assert({u_new.g_workers.lane[2].engine.ff_wa,u_new.g_workers.lane[2].engine.ff_wd}==={u_old.g_workers.lane[2].engine.ff_wa,u_old.g_workers.lane[2].engine.ff_wd})else $fatal(1,"refill sample mismatch instance3");
        if(ce)begin
          push3+=u_new.g_workers.lane[2].engine.q_we;pop3+=u_new.g_workers.lane[2].engine.q_pop;collision3+=u_new.g_workers.lane[2].engine.q_we&&u_new.g_workers.lane[2].engine.q_wa==u_new.g_workers.lane[2].engine.q_ra;
          full3+=(u_new.g_workers.lane[2].engine.q_cnt==16);mix3+=(u_new.g_workers.lane[2].engine.st==u_new.g_workers.lane[2].engine.S_MIX);cap3+=u_new.g_workers.lane[2].engine.cb_we;
          if(u_new.g_workers.lane[2].engine.q_cnt>maxq3)maxq3=u_new.g_workers.lane[2].engine.q_cnt;
        end
    end
    final $display("QUEUE_COVER instance3 push=%0d pop=%0d empty_collision=%0d full=%0d max=%0d mix=%0d capbytes=%0d",push3,pop3,collision3,full3,maxq3,mix3,cap3);
    always @(negedge clk) begin
    end

    longint push4=0,pop4=0,collision4=0,full4=0,mix4=0,cap4=0;int maxq4=0;
    always @(negedge clk)if(!rst)begin
        assert({u_new.g_workers.lane[3].engine.fs,u_new.g_workers.lane[3].engine.q_cnt,u_new.g_workers.lane[3].engine.q_wp,u_new.g_workers.lane[3].engine.q_rp,u_new.g_workers.lane[3].engine.q_we,u_new.g_workers.lane[3].engine.q_pop,u_new.g_workers.lane[3].engine.q_wa,u_new.g_workers.lane[3].engine.q_ra,u_new.g_workers.lane[3].engine.event_due_mask,u_new.g_workers.lane[3].engine.event_restart,u_new.g_workers.lane[3].engine.event_accept,u_new.g_workers.lane[3].engine.event_pop,u_new.g_workers.lane[3].engine.st,u_new.g_workers.lane[3].engine.cnt,u_new.g_workers.lane[3].engine.ent,u_new.g_workers.lane[3].engine.cb_we,u_new.g_workers.lane[3].engine.cb_be,u_new.g_workers.lane[3].engine.cb_wa,u_new.g_workers.lane[3].engine.ff_we,u_new.g_workers.lane[3].engine.tg_we,u_new.g_workers.lane[3].engine.service_active,u_new.g_workers.lane[3].engine.service_updates} === {u_old.g_workers.lane[3].engine.fs,u_old.g_workers.lane[3].engine.q_cnt,u_old.g_workers.lane[3].engine.q_wp,u_old.g_workers.lane[3].engine.q_rp,u_old.g_workers.lane[3].engine.q_we,u_old.g_workers.lane[3].engine.q_pop,u_old.g_workers.lane[3].engine.q_wa,u_old.g_workers.lane[3].engine.q_ra,u_old.g_workers.lane[3].engine.event_due_mask,u_old.g_workers.lane[3].engine.event_restart,u_old.g_workers.lane[3].engine.event_accept,u_old.g_workers.lane[3].engine.event_pop,u_old.g_workers.lane[3].engine.st,u_old.g_workers.lane[3].engine.cnt,u_old.g_workers.lane[3].engine.ent,u_old.g_workers.lane[3].engine.cb_we,u_old.g_workers.lane[3].engine.cb_be,u_old.g_workers.lane[3].engine.cb_wa,u_old.g_workers.lane[3].engine.ff_we,u_old.g_workers.lane[3].engine.tg_we,u_old.g_workers.lane[3].engine.service_active,u_old.g_workers.lane[3].engine.service_updates})else $fatal(1,"queue causal edge mismatch instance4");
        if(u_new.g_workers.lane[3].engine.q_we)assert(u_new.g_workers.lane[3].engine.q_wd===u_old.g_workers.lane[3].engine.q_wd)else $fatal(1,"queue input mismatch instance4");
        if(u_new.g_workers.lane[3].engine.fs==u_new.g_workers.lane[3].engine.F_RUN)assert(u_new.g_workers.lane[3].engine.q_q===u_old.g_workers.lane[3].engine.q_q)else $fatal(1,"queue consumed head mismatch instance4");
        for(int j=0;j<16;j++)assert(u_new.g_workers.lane[3].engine.u_queue.mem[j]===u_old.g_workers.lane[3].engine.u_queue.mem[j])else $fatal(1,"queue storage mismatch instance4");
        if(u_new.g_workers.lane[3].engine.cb_we)assert(u_new.g_workers.lane[3].engine.cb_wd===u_old.g_workers.lane[3].engine.cb_wd)else $fatal(1,"capture write sample mismatch instance4");
        if(u_new.g_workers.lane[3].engine.ff_we)assert({u_new.g_workers.lane[3].engine.ff_wa,u_new.g_workers.lane[3].engine.ff_wd}==={u_old.g_workers.lane[3].engine.ff_wa,u_old.g_workers.lane[3].engine.ff_wd})else $fatal(1,"refill sample mismatch instance4");
        if(ce)begin
          push4+=u_new.g_workers.lane[3].engine.q_we;pop4+=u_new.g_workers.lane[3].engine.q_pop;collision4+=u_new.g_workers.lane[3].engine.q_we&&u_new.g_workers.lane[3].engine.q_wa==u_new.g_workers.lane[3].engine.q_ra;
          full4+=(u_new.g_workers.lane[3].engine.q_cnt==16);mix4+=(u_new.g_workers.lane[3].engine.st==u_new.g_workers.lane[3].engine.S_MIX);cap4+=u_new.g_workers.lane[3].engine.cb_we;
          if(u_new.g_workers.lane[3].engine.q_cnt>maxq4)maxq4=u_new.g_workers.lane[3].engine.q_cnt;
        end
    end
    final $display("QUEUE_COVER instance4 push=%0d pop=%0d empty_collision=%0d full=%0d max=%0d mix=%0d capbytes=%0d",push4,pop4,collision4,full4,maxq4,mix4,cap4);
    always @(negedge clk) begin
    end


    genvar own; generate for(own=0;own<4;own++)begin:bank_state
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_config.g_word[0].g_byte[0].u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_config.g_word[0].g_byte[0].u_bank.mem[slot])else $fatal(1,"owned config stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_config.g_word[0].g_byte[1].u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_config.g_word[0].g_byte[1].u_bank.mem[slot])else $fatal(1,"owned config stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_config.g_word[0].g_byte[2].u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_config.g_word[0].g_byte[2].u_bank.mem[slot])else $fatal(1,"owned config stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_config.g_word[0].g_byte[3].u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_config.g_word[0].g_byte[3].u_bank.mem[slot])else $fatal(1,"owned config stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_config.g_word[1].g_byte[0].u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_config.g_word[1].g_byte[0].u_bank.mem[slot])else $fatal(1,"owned config stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_config.g_word[1].g_byte[1].u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_config.g_word[1].g_byte[1].u_bank.mem[slot])else $fatal(1,"owned config stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_config.g_word[1].g_byte[2].u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_config.g_word[1].g_byte[2].u_bank.mem[slot])else $fatal(1,"owned config stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_config.g_word[1].g_byte[3].u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_config.g_word[1].g_byte[3].u_bank.mem[slot])else $fatal(1,"owned config stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_config.g_word[2].g_byte[0].u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_config.g_word[2].g_byte[0].u_bank.mem[slot])else $fatal(1,"owned config stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_config.g_word[2].g_byte[1].u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_config.g_word[2].g_byte[1].u_bank.mem[slot])else $fatal(1,"owned config stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_config.g_word[2].g_byte[2].u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_config.g_word[2].g_byte[2].u_bank.mem[slot])else $fatal(1,"owned config stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_config.g_word[2].g_byte[3].u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_config.g_word[2].g_byte[3].u_bank.mem[slot])else $fatal(1,"owned config stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_config.g_word[3].g_byte[0].u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_config.g_word[3].g_byte[0].u_bank.mem[slot])else $fatal(1,"owned config stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_config.g_word[3].g_byte[1].u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_config.g_word[3].g_byte[1].u_bank.mem[slot])else $fatal(1,"owned config stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_config.g_word[3].g_byte[2].u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_config.g_word[3].g_byte[2].u_bank.mem[slot])else $fatal(1,"owned config stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_config.g_word[3].g_byte[3].u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_config.g_word[3].g_byte[3].u_bank.mem[slot])else $fatal(1,"owned config stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_runtime.g_byte[0].g_body.u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_runtime.g_byte[0].g_body.u_bank.mem[slot])else $fatal(1,"owned runtime stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_runtime.g_byte[1].g_body.u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_runtime.g_byte[1].g_body.u_bank.mem[slot])else $fatal(1,"owned runtime stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_runtime.g_byte[2].g_body.u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_runtime.g_byte[2].g_body.u_bank.mem[slot])else $fatal(1,"owned runtime stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_runtime.g_byte[3].g_body.u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_runtime.g_byte[3].g_body.u_bank.mem[slot])else $fatal(1,"owned runtime stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_runtime.g_byte[5].g_body.u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_runtime.g_byte[5].g_body.u_bank.mem[slot])else $fatal(1,"owned runtime stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_runtime.g_byte[6].g_body.u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_runtime.g_byte[6].g_body.u_bank.mem[slot])else $fatal(1,"owned runtime stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_runtime.g_byte[7].g_body.u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_runtime.g_byte[7].g_body.u_bank.mem[slot])else $fatal(1,"owned runtime stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_runtime.g_byte[8].g_body.u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_runtime.g_byte[8].g_body.u_bank.mem[slot])else $fatal(1,"owned runtime stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_runtime.g_byte[9].g_body.u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_runtime.g_byte[9].g_body.u_bank.mem[slot])else $fatal(1,"owned runtime stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_runtime.g_byte[10].g_body.u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_runtime.g_byte[10].g_body.u_bank.mem[slot])else $fatal(1,"owned runtime stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_runtime.g_byte[11].g_body.u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_runtime.g_byte[11].g_body.u_bank.mem[slot])else $fatal(1,"owned runtime stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_runtime.g_byte[12].g_body.u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_runtime.g_byte[12].g_body.u_bank.mem[slot])else $fatal(1,"owned runtime stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_runtime.g_byte[13].g_body.u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_runtime.g_byte[13].g_body.u_bank.mem[slot])else $fatal(1,"owned runtime stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_runtime.g_byte[14].g_body.u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_runtime.g_byte[14].g_body.u_bank.mem[slot])else $fatal(1,"owned runtime stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_runtime.g_byte[15].g_body.u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_runtime.g_byte[15].g_body.u_bank.mem[slot])else $fatal(1,"owned runtime stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_runtime.g_byte[16].g_body.u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_runtime.g_byte[16].g_body.u_bank.mem[slot])else $fatal(1,"owned runtime stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_runtime.g_byte[17].g_body.u_bank.mem[slot]===u_old.g_workers.lane[own].engine.g_owned_runtime.g_byte[17].g_body.u_bank.mem[slot])else $fatal(1,"owned runtime stored byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_runtime.loop_state[slot][0+:8]===u_old.g_workers.lane[own].engine.g_owned_runtime.loop_state[slot][0+:8])else $fatal(1,"owned live loop byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_runtime.loop_state[slot][8+:8]===u_old.g_workers.lane[own].engine.g_owned_runtime.loop_state[slot][8+:8])else $fatal(1,"owned live loop byte mismatch");
 always @(negedge clk)if(!rst)for(int slot=0;slot<4;slot++)assert(u_new.g_workers.lane[own].engine.g_owned_runtime.loop_state[slot][16+:8]===u_old.g_workers.lane[own].engine.g_owned_runtime.loop_state[slot][16+:8])else $fatal(1,"owned live loop byte mismatch");
end endgenerate

 genvar timer_owner;generate for(timer_owner=0;timer_owner<4;timer_owner++)begin:timer_sum_proof
 always @(negedge clk)if(!rst)begin
  assert(u_new.g_workers.lane[timer_owner].engine.tm_carry_s===u_old.g_workers.lane[timer_owner].engine.tm_s)else $fatal(1,"worker full18 timer sum mismatch");
  assert(u_new.g_workers.lane[timer_owner].engine.tm_sum===u_old.g_workers.lane[timer_owner].engine.tm_sum)else $fatal(1,"worker timer17 consumer mismatch");
 end
 end endgenerate

 integer parent_selects=0,parent_caps=0,parent_stores=0,parent_writes=0;
 always @(negedge clk)if(!rst)begin
  assert(u_old.st!=u_old.S_ITA && u_old.st!=u_old.S_ITB && u_old.st!=u_old.S_ITC && u_old.st!=u_old.S_FILL && u_old.st!=u_old.S_RETAG)else $fatal(1,"baseline parent voice invariant failed");
  if(u_old.st==u_old.S_CH || (u_old.st==u_old.S_LOAD && !u_old.ent[4]))assert(u_old.selpass && (u_old.ent==1 || u_old.ent==3))else $fatal(1,"baseline unselected voice dispatch");
  if(u_old.st==u_old.S_BOUND && !u_old.selpass)assert(u_old.ent>=16 && u_old.ent<=18 && !(|u_old.event_mask[15:0]))else $fatal(1,"baseline parent voice mask");
  if(u_old.q_we)assert(u_old.cfl_go && u_old.ent[4])else $fatal(1,"baseline parent read produced");
  if(u_old.fs==u_old.F_RUN)assert(u_old.h_we && !u_old.h_zero && u_old.h_n==1)else $fatal(1,"baseline parent read consumed");
  assert({u_new.event_due_mask,u_new.event_refresh,u_new.event_restart,u_new.worker_reg_pulse,u_new.worker_idle,u_new.event_mask,u_new.event_work_due,u_new.selpass,u_new.cnt,u_new.fs,u_new.q_cnt,u_new.q_wp,u_new.q_rp,u_new.q_we,u_new.q_pop,u_new.rr_we,u_new.rr_be,u_new.cb_we,u_new.cap_start,u_new.capcnt0,u_new.capcnt1}==={u_old.event_due_mask,u_old.event_refresh,u_old.event_restart,u_old.worker_reg_pulse,u_old.worker_idle,u_old.event_mask,u_old.event_work_due,u_old.selpass,u_old.cnt,u_old.fs,u_old.q_cnt,u_old.q_wp,u_old.q_rp,u_old.q_we,u_old.q_pop,u_old.rr_we,u_old.rr_be,u_old.cb_we,u_old.cap_start,u_old.capcnt0,u_old.capcnt1})else $fatal(1,"parent DUE/order/capture state mismatch");
  if(u_new.rr_we)assert(u_new.rr_wd===u_old.rr_wd)else $fatal(1,"parent runtime payload mismatch");
  if(u_new.cb_we)assert({u_new.cb_wa,u_new.cb_be,u_new.cb_wd}==={u_old.cb_wa,u_old.cb_be,u_old.cb_wd})else $fatal(1,"parent capture payload mismatch");
  if(ce)begin
   if(u_old.st==u_old.S_CH)parent_selects++;
   if(u_old.st==u_old.S_CAPA)parent_caps++;
   if(u_old.st==u_old.S_STORE)parent_stores++;
   if(o_mem_req && mem_ack && o_mem_we)parent_writes++;
  end
  if(cyc>=cycles-1)$display("PARENT59_COVER selects=%0d caps=%0d stores=%0d writes=%0d",parent_selects,parent_caps,parent_stores,parent_writes);
 end

 longint edge_capture_writes=0,edge_parent_pops=0,edge_capture_bytes=0;
 always @(posedge clk)if(ce && !rst)begin
  assert({u_new.q_pop,u_new.q_we,u_new.cb_we,u_new.rr_we,u_new.reg_ack,u_new.event_pop,u_new.event_due_mask}==={u_old.q_pop,u_old.q_we,u_old.cb_we,u_old.rr_we,u_old.reg_ack,u_old.event_pop,u_old.event_due_mask})else $fatal(1,"accepted-edge parent causal mismatch");
  if(u_new.mem_req && mem_ack)begin
   assert({u_new.mem_we,u_new.mem_n4,u_new.mem_addr,u_new.mem_wdata}==={u_old.mem_we,u_old.mem_n4,u_old.mem_addr,u_old.mem_wdata})else $fatal(1,"accepted-edge memory payload mismatch");
   if(u_new.mem_we)edge_capture_writes++;
  end
  if(u_new.q_pop)edge_parent_pops++;
  if(u_new.cb_we)edge_capture_bytes++;
  for(int a=0;a<8;a++)assert(u_new.u_cb.mem[a]===u_old.u_cb.mem[a])else $fatal(1,"physical capture RAM mismatch");
 end
 final begin
  assert(edge_capture_writes>0 && edge_parent_pops>0 && edge_capture_bytes>0)else $fatal(1,"missing accepted-edge capture coverage");
  $display("ACCEPTED_EDGE_CAPTURE writes=%0d pops=%0d bytewrites=%0d",edge_capture_writes,edge_parent_pops,edge_capture_bytes);
 end

 genvar scope62;generate for(scope62=0;scope62<4;scope62++)begin:original_worker_contract
 always @(posedge clk)if(ce && !rst)begin
  assert(!u_old.g_workers.lane[scope62].engine.selpass && !u_old.g_workers.lane[scope62].engine.event_output && !(|(u_old.g_workers.lane[scope62].engine.event_mask & ~(18'h01111<<scope62))))else $fatal(1,"original worker nonvoice mask");
  assert(u_old.g_workers.lane[scope62].engine.st!=u_old.g_workers.lane[scope62].engine.S_CAP && u_old.g_workers.lane[scope62].engine.st!=u_old.g_workers.lane[scope62].engine.S_CAPA && u_old.g_workers.lane[scope62].engine.st!=u_old.g_workers.lane[scope62].engine.S_CFL && u_old.g_workers.lane[scope62].engine.st!=u_old.g_workers.lane[scope62].engine.S_OUT && u_old.g_workers.lane[scope62].engine.st!=u_old.g_workers.lane[scope62].engine.S_WORK)else $fatal(1,"original worker capture state");
  if(u_old.g_workers.lane[scope62].engine.q_we)assert(u_old.g_workers.lane[scope62].engine.st==u_old.g_workers.lane[scope62].engine.S_FILL && !u_old.g_workers.lane[scope62].engine.ent[4] && !u_old.g_workers.lane[scope62].engine.q_wd[70])else $fatal(1,"original worker write produced");
  if(u_old.g_workers.lane[scope62].engine.fs==u_old.g_workers.lane[scope62].engine.F_RUN)assert(!u_old.g_workers.lane[scope62].engine.h_we)else $fatal(1,"original worker write consumed");
  assert({u_new.g_workers.lane[scope62].engine.worker_postvol0,u_new.g_workers.lane[scope62].engine.worker_postvol2}==={u_old.g_workers.lane[scope62].engine.worker_postvol0,u_old.g_workers.lane[scope62].engine.worker_postvol2})else $fatal(1,"live postvol taps mismatch");
 end
 end endgenerate
endmodule
