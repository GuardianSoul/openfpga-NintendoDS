// Sound engine equivalence: rtl/sound against an earlier revision (old_sound,
// renamed by snd_eq.sh), side by side on random ARM7 register traffic, ticks
// and memory latency, every output compared every cycle. Both engines see
// the same acks and read data, driven from the new one's requests, so the
// first difference in a request is reported where it happens.
module tb_snd_eq;
    logic clk = 0, rst = 1, ce = 1, tick = 0;
    logic        reg_req = 0, reg_we = 0;
    logic [1:0]  reg_size = 2;
    logic [8:0]  reg_addr = 0;
    logic [31:0] reg_wdata = 0;
    logic        mem_ack = 0, mem_rvalid = 0;
    logic [31:0] mem_rdata = 0;
    logic        n_reg_ack, o_reg_ack, n_mem_req, o_mem_req, n_mem_we, o_mem_we;
    logic [31:0] n_reg_rdata, o_reg_rdata, n_mem_wdata, o_mem_wdata;
    logic [24:0] n_mem_addr, o_mem_addr;
    logic        n_out_valid, o_out_valid, n_overrun, o_overrun, n_late, o_late;
    logic [15:0] n_out_l, o_out_l, n_out_r, o_out_r;
    logic [9:0]  n_dac_l, o_dac_l, n_dac_r, o_dac_r;
    sound u_new (.clk, .ce, .rst, .tick, .power(1'b1), .reg_req, .reg_we, .reg_size, .reg_addr, .reg_wdata,
        .reg_ack(n_reg_ack), .reg_rdata(n_reg_rdata), .mem_req(n_mem_req), .mem_we(n_mem_we), .mem_addr(n_mem_addr),
        .mem_wdata(n_mem_wdata), .mem_ack, .mem_rvalid, .mem_rdata, .out_valid(n_out_valid), .out_l(n_out_l),
        .out_r(n_out_r), .dac_l(n_dac_l), .dac_r(n_dac_r), .overrun(n_overrun), .late(n_late));
    old_sound u_old (.clk, .ce, .rst, .tick, .power(1'b1), .reg_req, .reg_we, .reg_size, .reg_addr, .reg_wdata,
        .reg_ack(o_reg_ack), .reg_rdata(o_reg_rdata), .mem_req(o_mem_req), .mem_we(o_mem_we), .mem_addr(o_mem_addr),
        .mem_wdata(o_mem_wdata), .mem_ack, .mem_rvalid, .mem_rdata, .out_valid(o_out_valid), .out_l(o_out_l),
        .out_r(o_out_r), .dac_l(o_dac_l), .dac_r(o_dac_r), .overrun(o_overrun), .late(o_late));

    int unsigned seed = 1, cycles = 2000000, half = 0;
    longint bad = 0, n_itc = 0, n_out = 0, n_rd = 0;
    logic [24:0] rq [$];
    always #1 clk = ~clk;

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
        void'($urandom(seed));
        repeat (4) @(negedge clk);
        rst = 0;
    end

    int unsigned cyc = 0, tcnt = 0, gap = 0;
    always @(negedge clk) begin
        cyc++;
        // outputs, compared before every edge
        if (!rst && (n_reg_ack !== o_reg_ack || (n_reg_ack && n_reg_rdata !== o_reg_rdata) ||
            n_mem_req !== o_mem_req || (n_mem_req && (n_mem_we !== o_mem_we || n_mem_addr !== o_mem_addr ||
            (n_mem_we && n_mem_wdata !== o_mem_wdata))) || n_out_valid !== o_out_valid || n_out_l !== o_out_l ||
            n_out_r !== o_out_r || n_dac_l !== o_dac_l || n_dac_r !== o_dac_r || n_overrun !== o_overrun || n_late !== o_late)) begin
            bad++;
            if (bad <= 5) $display("cycle %0d: new ack %b rd %h req %b we %b a %h out %b %h %h | old ack %b rd %h req %b we %b a %h out %b %h %h",
                cyc, n_reg_ack, n_reg_rdata, n_mem_req, n_mem_we, n_mem_addr, n_out_valid, n_out_l, n_out_r,
                o_reg_ack, o_reg_rdata, o_mem_req, o_mem_we, o_mem_addr, o_out_valid, o_out_l, o_out_r);
        end
        if (u_new.st == u_new.S_ITC && ce) n_itc++;
        if (n_out_valid && ce) n_out++;
        if (cyc >= cycles) begin
            if (bad) $write("DIFFER"); else $write("EQUIVALENT");
            $display(": %0d cycles, %0d differing (seed %0d, half %0d): %0d output steps, %0d ADPCM decodes, %0d memory reads",
                cycles, bad, seed, half, n_out, n_itc, n_rd);
            $finish;
        end
        // half: the engine's ce every other clk; the stimulus changes only on ce edges
        if (half) ce = !ce;
        if (!half || ce) begin
            // memory: an ack per request edge at random, reads answer in order 0-12 edges later
            mem_ack = n_mem_req && ($urandom % 4 != 0);   // taken at the next edge
            if (mem_ack && !n_mem_we) begin rq.push_back(n_mem_addr); n_rd++; end
            mem_rvalid = 0;
            if (rq.size() != 0 && ($urandom % 3 == 0)) begin mem_rvalid = 1; mem_rdata = h32({7'd0, rq.pop_front()} ^ seed); end
            // ticks: one per 1,024 engine clocks
            tick = 0;
            if (++tcnt == 1024) begin tcnt = 0; tick = 1; end
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
                end
            end
        end
    end
endmodule
