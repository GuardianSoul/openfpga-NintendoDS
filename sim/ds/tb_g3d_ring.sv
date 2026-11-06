// nds_g3d_ring unit test: a raster that finishes lines after random render
// times (gated by y_lim, 256 pixels a line, one a clock), a display that
// composes line d at 4,260-clock intervals (frames start at line 215; l3d_go
// then l3d_line a clock later, as nds_disp) and reads its 256 pixels through
// l3d_raddr, and an SDRAM that serves 32-byte block reads and writes after
// random latencies. A line the ring holds complete when its composition
// starts must read back as that frame's pixels; the others are late. Some
// frames are cut short (a restart).
//   +seed=S +frames=N +heavy=P (one line in P renders 3-8 lines long) +slow=C (render time scale)
//   +wlag=W (a written word reaches the memory 1..W clocks later; rg_wdrained when none is on its way)
//   -GLLR=1: the raster's four line buffers (lb: the clear colour, then a
//   line's pixels drawn left to right over its render time) behind the ll_*
//   port (refused one clock in four, as the final pass takes it); a late line
//   the ring copied must read back as drawn so far: a prefix of the line's
//   pixels, the clear colour after it
module tb_g3d_ring #(parameter int YLAG = 0, parameter bit LLR = 0, parameter bit RPRI = 0, parameter bit NX2 = 0, parameter bit TR3 = 0);
    localparam int LS = TR3 ? 3 : 4;      // the raster's line buffer slots (TR3: line mod 3)
    logic clk = 0;
    always #5 clk = !clk;
    logic rst = 1;
    logic        frame_go = 0, l3d_go = 0;
    logic [7:0]  l3d_line = 0, l3d_raddr = 0;
    logic [22:0] l3d_rdata;
    logic [8:0]  y_lim;
    logic        px_valid = 0;
    logic [7:0]  px_x = 0, px_y = 0;
    logic [22:0] px_color = 0;
    logic        rg_wreq, rg_wack = 0, rg_rreq, rg_rack = 0, rg_rvalid = 0;
    logic [23:0] rg_waddr, rg_raddr;
    logic [31:0] rg_wdata, rg_rdata = 0;
    logic        rg_wdrained;
    logic        l3d_have;
    logic [3:0]  st_busy;
    logic        ll_rd, ll_ack;
    logic [1:0]  ll_slot;
    logic [7:0]  ll_x, fp_line = 8'd0;
    logic [8:0]  r_go = 9'd0;
    logic        fp_act = 1'b0;
    logic [22:0] ll_q = '0;
    localparam logic [22:0] CLR = 23'h2A5A5A;
    int fp_fin [192];                      // the frame whose final pass finished each line
    initial foreach (fp_fin[i]) fp_fin[i] = -1;
    // a copy may only start for a line the final pass has not finished (its slot is cleared)
    logic est_lc_q = 0;
    always @(posedge clk) if (LLR) begin
        est_lc_q <= dut.est == 3'd6;
        if (dut.est == 3'd6 && !est_lc_q && fp_fin[dut.lc_y] == frame) begin
            errs++;
            if (errs < 10) $display("frame %0d: a copy of line %0d, which the final pass has finished", frame, dut.lc_y);
        end
    end
    logic [22:0] lb [4][256];
    logic        ll_rnd = 1'b0;
    always @(posedge clk) ll_rnd <= $urandom % 4 != 0;
    // the raster refuses the read while the final pass reads that slot (its lines f-1, f, f+1; it keeps
    // them while it holds on a full staging slot)
    wire   fp_on_slot = fp_act && (int'(ll_slot) == (int'(fp_line) + LS - 1) % LS || int'(ll_slot) == int'(fp_line) % LS || int'(ll_slot) == (int'(fp_line) + 1) % LS);
    assign ll_ack = ll_rd && ll_rnd && !fp_on_slot;
    always @(posedge clk) ll_q <= lb[ll_slot][ll_x];      // (the ring holds line l3d_line; nds_gpu3d shows the rear plane otherwise)
    // YLAG (-GYLAG=2): the producer is the final pass, YLAG lines behind the
    // line the store streams (y_lim gates y + YLAG, up to 191), and it holds
    // each pixel while its line's staging slot is still full (st_busy)
    nds_g3d_ring #(.YLAG(YLAG), .LLR(LLR), .RPRI(RPRI), .NX2(NX2), .TR3(TR3)) dut (.*);

    function automatic logic [22:0] pix(input int f, input int y, input int x);
        logic [31:0] h = 32'(f) * 32'h9E3779B1 ^ 32'(y) * 32'h85EBCA6B ^ 32'(x) * 32'hC2B2AE35;
        return h[22:0] ^ h[31:9];
    endfunction

    int seed = 1, frames = 30, heavy = 40, slow = 100, wlag = 150, wfix = 0, skip = 0;
    longint part = 0, part_px = 0, errs = 0, late = 0, checked = 0, wblk = 0, rblk = 0, restarts = 0, stale = 0;
    initial begin
        void'($value$plusargs("seed=%d", seed));
        void'($value$plusargs("frames=%d", frames));
        void'($value$plusargs("heavy=%d", heavy));
        void'($value$plusargs("slow=%d", slow));
        void'($value$plusargs("wlag=%d", wlag));
        void'($value$plusargs("wfix=%d", wfix));
        void'($value$plusargs("skip=%d", skip));     // the display skips a line's composition, one in N (a late 2D line)     // ... or exactly this many     // writes reach the memory up to this many clocks late
        void'($urandom(seed));
    end

    // SDRAM (integration's ring ports): writes take a word per rg_wack (random
    // gaps); a read is acked after a random wait, then 8 words (random gaps)
    logic [31:0] mem [int];
    int          wq_a [$];
    logic [31:0] wq_d [$];
    longint      wq_t [$];
    longint      cyc = 0;
    always @(posedge clk) cyc++;
    // drained: no write waiting to reach the memory (a clock late, as the Pocket's)
    always @(posedge clk) rg_wdrained <= wq_t.size() == 0 && !rg_wack;
    int          sm_st = 0, sm_cnt = 0, sm_k = 0;
    logic [23:0] sm_a;
    always @(posedge clk) begin
        rg_wack <= 0; rg_rack <= 0; rg_rvalid <= 0;
        if (rst) sm_st <= 0;
        else begin
            // writes: the word on rg_wdata is taken at an edge with rg_wack, and
            // reaches the memory (what reads see) 1-150 clocks later, in order
            if (rg_wack) begin
                wq_a.push_back(int'(rg_waddr)); wq_d.push_back(rg_wdata);
                wq_t.push_back(cyc + 1 + (wfix > 0 ? wfix : $urandom % wlag));
                if (rg_waddr[2:0] == 3'd7) wblk++;
            end
            while (wq_t.size() > 0 && wq_t[0] <= cyc) begin
                mem[wq_a[0]] = wq_d[0]; void'(wq_a.pop_front()); void'(wq_d.pop_front()); void'(wq_t.pop_front());
            end
            if (rg_wreq && !rg_wack && $urandom % 3 != 0) rg_wack <= 1;
            case (sm_st)
                0: if (rg_rreq && !rg_rack) begin sm_cnt <= 1 + $urandom % 30; sm_st <= 1; end
                1: if (sm_cnt > 1) sm_cnt <= sm_cnt - 1;
                   else begin rg_rack <= 1; sm_a <= rg_raddr; sm_k <= 0; rblk++; sm_cnt <= 8 + $urandom % 20; sm_st <= 3; end
                default: if (sm_cnt > 0) sm_cnt <= sm_cnt - 1;
                   else if ($urandom % 4 != 0) begin
                       rg_rvalid <= 1; rg_rdata <= mem.exists(int'(sm_a) + sm_k) ? mem[int'(sm_a) + sm_k] : 32'hDEADBEEF;
                       foreach (wq_a[i]) if (wq_a[i] == int'(sm_a) + sm_k) begin stale++; break; end
                       if (sm_k == 7) sm_st <= 0; else sm_k <= sm_k + 1;
                   end
            endcase
        end
    end

    // display
    int vline = 200, vpos = 0, frame = 0;
    int sweep_x = -1, sweep_d = 0;
    bit sweep_ok, sweep_p;
    bit sk;
    int sweep_k;                        // a partial line: its drawn prefix so far
    always @(posedge clk) if (!rst) begin
        l3d_go <= 0; frame_go <= 0;
        vpos++;
        if (vpos == 4260) begin
            vpos = 0;
            vline = vline == 262 ? 0 : vline + 1;
            if (vline == 215) begin frame_go <= 1; frame++; end
            sk = 1'b0;
            if (skip > 0 && vline > 0) sk = $urandom % skip == 0;   // (no draw when off: the seeds' streams stay)
            if (vline < 192 && !sk) begin
                l3d_go <= 1;
                sweep_d = vline;
                sweep_ok = dut.rb_v[vline[0]] && dut.rb_y[vline[0]] == 8'(vline);
                sweep_p = sweep_ok && dut.rb_p[vline[0]];
                sweep_k = 0;
                sweep_x = 0;
            end
        end
        if (vpos == 1 && sweep_x == 0) l3d_line <= 8'(sweep_d);   // a clock after l3d_go
        // the read sweep: address at vpos 2..257, data a clock later
        if (sweep_x >= 0 && vpos >= 2) begin
            if (vpos >= 4) begin
                int x;
                x = vpos - 4;   // address set at vpos 2 + x, seen the clock after, data the next
                if (sweep_p) begin
                    // drawn so far: the line's pixels up to some x, the clear colour after
                    if (l3d_rdata == pix(frame, sweep_d, x) && sweep_k == x) sweep_k++;
                    else if (l3d_rdata != CLR) begin
                        errs++;
                        if (errs < 10) $display("frame %0d late line %0d x %0d: %h, neither its pixel (prefix to %0d) nor the clear colour", frame, sweep_d, x, l3d_rdata, sweep_k);
                    end
                end else if (sweep_ok && l3d_rdata != pix(frame, sweep_d, x)) begin
                    errs++;
                    if (errs < 10) $display("frame %0d line %0d x %0d: %h, expected %h", frame, sweep_d, x, l3d_rdata, pix(frame, sweep_d, x));
                end
                if (x == 255) begin
                    if (sweep_p) begin part++; part_px += sweep_k; end
                    else if (sweep_ok) checked++; else late++;
                    sweep_x = -1;
                end
            end
            if (vpos <= 257) l3d_raddr <= 8'(vpos - 2);
        end
    end

    // raster: one thread per frame (automatic: the threads share nothing)
    int rf_last = -1;
    task automatic draw_frame(input int f);
        r_go <= 9'd0;
        for (int y = 0; y < 192; y++) begin
            int t;
            t = ($urandom % heavy == 0) ? 4260 * (3 + $urandom % 6) : (600 + $urandom % 3000) * slow / 100;
            while (dut.y_lim < 9'(y + YLAG > 191 ? 191 : y + YLAG) && frame == f) @(posedge clk);
            // the line buffer: the clear colour, then the pixels left to right
            for (int x = 0; x < 256; x++) lb[y % LS][x] = CLR;
            r_go <= 9'(y + 1);
            for (int i = 0, k = 0; i < t; i++) begin
                if (frame != f) break;
                @(posedge clk);
                for (; k <= i * 256 / t; k++) lb[y % LS][k] = pix(f, y, k);
            end
            if (frame != f) begin restarts++; return; end
            fp_act <= 1'b1; fp_line <= 8'(y);         // the final pass reads lines y-1 .. y+1 from here on
            for (int x = 0; x < 256; x++) begin
                if (frame != f) break;
`ifndef YLAG_NOHOLD
                begin
                    int hc;
                    hc = 0;
                    while (YLAG > 0 && st_busy[y % 4] && frame == f) begin
                        px_valid <= 0; @(posedge clk);
                        if (++hc == 100000) begin $display("ERROR: the final pass held 100K clocks on staging slot %0d (est %0d)", y % 4, dut.est); errs++; $fatal(1); end
                    end
                end
                if (frame != f) break;
`endif
                px_valid <= 1; px_x <= 8'(x); px_y <= 8'(y); px_color <= pix(f, y, x);
                fp_act <= 1'b1; fp_line <= 8'(y);
                @(posedge clk);
            end
            px_valid <= 0; fp_act <= 1'b0;
            if (frame != f) begin restarts++; return; end
            // the final pass of line y has cleared line y-1's slot (FPCLR); line y is through it
            for (int x = 0; x < 256; x++) lb[(y + LS - 1) % LS][x] = CLR;
            fp_fin[y] = f;
        end
    endtask
    initial begin
        repeat (4) @(posedge clk);
        rst = 0;
        while (frame < frames) begin
            @(posedge clk);
            if (frame_go && frame != rf_last) begin
                rf_last = frame;
                fork draw_frame(frame); join_none
            end
        end
        if (LLR) $display("LLR: %0d late lines copied as drawn so far (%0d pixels drawn of %0d)", part, part_px, part * 256);
        $display("tb_g3d_ring: %0d frames, %0d lines checked, %0d late, %0d block writes, %0d block reads, %0d restarts, %0d words read before their write landed: %0d errors",
                 frames, checked, late, wblk, rblk, restarts, stale, errs);
        if (errs || stale || checked == 0) begin $display("FAIL"); $fatal(1); end
        $display("PASS");
        $finish;
    end
endmodule
