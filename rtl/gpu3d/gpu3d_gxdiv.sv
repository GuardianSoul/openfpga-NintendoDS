// Unsigned 64/32 divider for the geometry engine (docs/geometry-engine.md):
// restoring, one quotient bit per clock, returns the low 32 bits of
// floor(num / den). The caller states how many quotient bits it expects
// (qb: 10, 16, 32 or 64); the division starts there, and if num >> qb is
// not below den (a larger quotient) it restarts with all 64 bits, so the
// result is exact for any input. Signs are handled in microcode.
module gpu3d_gxdiv #(
    parameter bit SMALL = 1'b1,        // 0: the first version (magnitude compares); 1: the same test as an OR
    parameter bit R4 = 1'b0,           // 1 (SMALL only): two quotient bits per clock (the bit counts are even)
    // P2X (with R4): R4's two bits a clock from one subtractor on clk2 (2 x clk, phase 0: one bit at the middle
    // edge, one at the next clk edge), the same quotients, busy and q at the same clk edges (below)
    parameter bit P2X = 1'b0
) (
    input  logic        clk,
    input  logic        clk2,          // P2X: 2 x clk, rising with it
    input  logic        rst,
    input  logic        start,
    input  logic [1:0]  qb,            // 0: 10, 1: 16, 2: 32, 3: 64 quotient bits
    input  logic [63:0] num,
    input  logic [31:0] den,
    output logic        busy,
    output logic [31:0] q
);
    // the remainder before the first step must be below den
    function automatic [32:0] top(input [63:0] v, input [1:0] b);
        case (b)
            2'd0: top = (SMALL ? |v[63:42] : v[63:10] > 54'(32'hFFFFFFFF)) ? 33'h1FFFFFFFF : {1'b0, v[41:10]};
            2'd1: top = (SMALL ? |v[63:48] : v[63:16] > 48'(32'hFFFFFFFF)) ? 33'h1FFFFFFFF : {1'b0, v[47:16]};
            2'd2: top = {1'b0, v[63:32]};
            default: top = 33'd0;
        endcase
    endfunction
    function automatic [6:0] bits(input [1:0] b);
        case (b) 2'd0: bits = 7'd10; 2'd1: bits = 7'd16; 2'd2: bits = 7'd32; default: bits = 7'd64; endcase
    endfunction

    logic [6:0] dbg_cnt;               // the quotient bits still to come (tb_geom --prof)
    generate if (P2X) begin : g_p2x
        // clk: busy, first, cnt, the numerator and the quotient, as R4 keeps them. clk2: the remainder r, the
        // divisor, and the step's inputs, so the subtractor's loop is clk2's alone. At the clk edge E that
        // ends a busy clock, R4 takes bits cnt - 1 and cnt - 2; here the middle edge M takes bit cnt - 1 (its
        // quotient bit into qm) and E bit cnt - 2 (into qr with qm). What clk2 takes from clk-domain logic it
        // takes at E only (nb1, nb2, f2, a start's load: clk_sys -> clk_2x is a whole clk cycle, setup 2);
        // clk reads clk2's registers (r, qm, rsf) at E, half a clk cycle after M.
        logic        busy_q, first;
        logic [6:0]  cnt;
        logic [63:0] nfull;
        logic [31:0] qr;
        logic [32:0] r;
        logic [31:0] d;
        logic        nb1, nb2, qm, rsf, f2;
        logic        tg = 1'b0, tq = 1'b0, ph = 1'b0;   // ph: 1 from E to M (the next clk2 edge is M), as nds_lcache
        // R4's first-clock test (the quotient has more bits than stated: restart with all 64), taken at M
        // from the loaded r
        wire         rst64 = rsf;
        // clk's next values of cnt and first, for clk2's step inputs at E; a start's first two bits are bits
        // 9/8, 15/14, 31/30 or 63/62 of num (no numerator mux in front of the bit select)
        wire  [6:0]  cnt_n   = start ? bits(qb) : busy_q ? (rst64 ? 7'd64 : cnt - 7'd2) : cnt;
        // the bit counts are even: the next clock's bits cnt - 1, cnt - 2 are pair (cnt / 2 - 1) of the numerator
        wire  [4:0]  pr_n    = busy_q ? (rst64 ? 5'd31 : cnt[5:1] - 5'd2) : cnt[5:1] - 5'd1;
        wire  [1:0]  nb_pr   = nfull[{pr_n, 1'b0} +: 2];
        wire  [1:0]  nb_st   = qb == 2'd0 ? num[9:8] : qb == 2'd1 ? num[15:14] : qb == 2'd2 ? num[31:30] : num[63:62];
        wire         first_n = start ? qb != 2'd3 : busy_q ? 1'b0 : first;
        // one step: the next numerator bit (M: nb1, E: nb2) brought down
        wire         nb   = ph ? nb1 : nb2;
        wire  [33:0] sh   = {r, nb};
        wire  [34:0] dif  = {1'b0, sh} - {3'b0, d};
        wire  [32:0] r_st = !dif[34] ? dif[32:0] : sh[32:0];
        always_ff @(posedge clk) tg <= !tg;
        always_ff @(posedge clk2) begin
            tq <= tg;
            ph <= tg == tq;
            if (ph) begin
                // M: bit cnt - 1; R4's restart test on the r the clock started with
                rsf <= f2 && r >= {1'b0, d};
                qm  <= !dif[34];
                r   <= r_st;
            end else begin
                // E: a start loads; else bit cnt - 2 (or the restart's clear)
                if (start) begin
                    r <= top(num, qb); d <= den;
                end else r <= rst64 ? 33'd0 : r_st;
                nb1 <= start ? nb_st[1] : nb_pr[1];
                nb2 <= start ? nb_st[0] : nb_pr[0];
                f2  <= first_n;
            end
        end
        always_ff @(posedge clk) begin
            if (rst) begin
                busy_q <= 1'b0; first <= 1'b0; cnt <= 7'd0;
            end else begin
                first <= first_n; cnt <= cnt_n;
                if (start) begin
                    busy_q <= 1'b1; nfull <= num; qr <= 32'd0;
                end else if (busy_q) begin
                    if (rst64) qr <= 32'd0;
                    else begin
                        qr <= {qr[29:0], qm, !dif[34]};
                        if (cnt == 7'd2) busy_q <= 1'b0;
                    end
                end
            end
        end
        assign busy = busy_q;
        assign dbg_cnt = cnt;
        assign q = qr;
`ifndef SYNTHESIS
        // synthesis translate_off
        // R4 beside it on the same inputs: busy and q at every clk edge
        logic        busy_r;
        logic [31:0] q_r;
        gpu3d_gxdiv #(.SMALL(1'b1), .R4(1'b1), .P2X(1'b0)) u_ref (.clk, .clk2(1'b0), .rst, .start, .qb, .num, .den,
                                                                  .busy(busy_r), .q(q_r));
        always_ff @(posedge clk)
            if (!rst && (busy_r != busy_q || q_r != qr))
                $error("gpu3d_gxdiv P2X: busy %0d q %08x, R4 busy %0d q %08x (clk2 driven?)", busy_q, qr, busy_r, q_r);
        initial if (!(SMALL && R4)) $error("gpu3d_gxdiv: P2X needs SMALL and R4");
        // synthesis translate_on
`endif
    end else begin : g_p1
        logic [32:0] r;                    // partial remainder (< 2 * den)
        logic [63:0] n;                    // numerator bits still to bring down, MSB first
        logic [63:0] nfull;                // for the restart
        logic [31:0] d;
        logic [31:0] qr;                   // the quotient
        logic [6:0]  cnt;
        logic        first;

        function automatic [63:0] low(input [63:0] v, input [1:0] b);
            case (b)
                2'd0: low = {v[9:0], 54'd0};
                2'd1: low = {v[15:0], 48'd0};
                2'd2: low = {v[31:0], 32'd0};
                default: low = v;
            endcase
        endfunction

        // SMALL: the numerator stays in nfull as it was at the start, and each step brings down its bit
        // cnt - 1 (cnt counts the quotient bits still to come: from 10/16/32/64, or 64 after a restart), so
        // there is no shifting copy and the restart needs no reload. Cycle-identical, the same partial quotients.
        wire        nmsb = SMALL ? nfull[cnt[5:0] - 6'd1] : n[63];
        wire [33:0] sh  = {r, nmsb};
        wire [34:0] dif = {1'b0, sh} - {3'b0, d};
        // R4: the next bit's step after this one, in the same clock
        wire [32:0] r1   = !dif[34] ? dif[32:0] : sh[32:0];
        wire        nb2  = nfull[cnt[5:0] - 6'd2];
        wire [33:0] sh2  = {r1, nb2};
        wire [34:0] dif2 = {1'b0, sh2} - {3'b0, d};
        always_ff @(posedge clk) begin
            if (rst) begin
                busy <= 1'b0; first <= 1'b0; cnt <= 7'd0;
            end else if (start) begin
                busy <= 1'b1; first <= qb != 2'd3;
                d <= den; nfull <= num;
                r <= top(num, qb); cnt <= bits(qb); qr <= 32'd0;
                if (!SMALL) n <= low(num, qb);
            end else if (busy) begin
                first <= 1'b0;
                if (first && r >= {1'b0, d}) begin
                    // the quotient has more bits than stated: all 64
                    r <= 33'd0; cnt <= 7'd64; qr <= 32'd0;
                    if (!SMALL) n <= nfull;
                end else if (R4 && SMALL) begin
                    r <= !dif2[34] ? dif2[32:0] : sh2[32:0];
                    qr <= {qr[29:0], !dif[34], !dif2[34]};
                    cnt <= cnt - 7'd2;
                    if (cnt == 7'd2) busy <= 1'b0;
                end else begin
                    if (!dif[34]) r <= dif[32:0];
                    else r <= sh[32:0];
                    qr <= {qr[30:0], !dif[34]};
                    if (!SMALL) n <= {n[62:0], 1'b0};
                    cnt <= cnt - 7'd1;
                    if (cnt == 7'd1) busy <= 1'b0;
                end
            end
        end
        assign q = qr;
        assign dbg_cnt = cnt;
    end endgenerate
endmodule
