// ARM9 divider and square root (0x280..0x2BF), after melonDS NDS::DivDone,
// StartDiv, SqrtDone and StartSqrt.
//
// Busy times are melonDS's, in system cycles: DIV 18 (32/32) or 34 (64/32,
// 64/64), SQRT 13. `tick` marks the clk (67.03 MHz) cycle that ends a system
// cycle, so a write at clk cycle n is done for reads at cycles m with
// (m>>1) >= (n>>1) + latency, as melonDS's event timestamps give. Results
// and the busy bit change together at that edge; until then reads return
// the old results, as in melonDS.
//
// The divider is restoring, one bit per clk on one 65-bit adder: a setup
// cycle (|N| on the adder), 32 or 64 iterations (divisor sign folded into
// add/subtract), then the results are committed. Quotient and remainder are
// kept as magnitudes with a sign and negated when read, by one 32-bit
// incrementer on the read path (the high word adds the low word's
// all-zero carry, a flag kept at the commit).
//
// The results live in a RAM of two banks (u_res, 64-bit words {kind, bank}):
// a unit writes its next result into the bank not being read, and the commit
// only flips that unit's bank bit, so results still change together with the
// busy bit. The quotient is written in the last iteration (from the adder's
// last bit), the remainder in the D_WAIT cycles, the root in the S_WAIT
// cycles the divider leaves free. Reads take the RAM's output register: the
// result word comes back the cycle after the read (res_q), with its sign,
// carry and cleared flags sampled at the read edge. 1 + 32 + 1 = 34 clks fits the 35-clk minimum of DIV 18;
// 1 + 64 + 1 = 66 fits 67 for DIV 34. The square root does two bit steps
// per clk (16 clks for 64 bits, 25 allowed), non-restoring.
// Divide by zero and the overflow cases fall out of the datapath as melonDS
// writes them; only 32-bit INT_MIN / -1 needs a flag (melonDS leaves the
// remainder unchanged there). A write in the last busy cycle restarts the
// unit without committing, as it cancels melonDS's pending event.
//
// Writes follow melonDS's handlers: DIVCNT/SQRTCNT take 16- and 32-bit
// writes, the operands only 32-bit writes; each restarts its unit.
module sys_math #(
    parameter bit PUMP = 0              // u_res double-pumped on clk2 (sys_ram64p)
) (
    input  logic        clk,
    input  logic        clk2,
    input  logic        rst,
    input  logic        tick,
    input  logic        we,
    input  logic [3:0]  be,
    input  logic [3:0]  wa,         // word index from 0x280
    input  logic [31:0] wdata,
    input  logic [3:0]  ra,
    output logic [31:0] rdata,      // control bits; the results come on res_q
    output logic [31:0] res_q,      // the result word read the cycle before
    output logic        late        // simulation check: a result missed its deadline
);
    logic [15:0] divcnt, sqrtcnt;
    logic [63:0] num, den, param;
    logic        quot_neg, remr_neg;    // the committed results' signs (magnitudes in u_res)
    logic        quot_z, remr_z;        // their low words are 0 (the high word's negation carry)
    logic        bq, br, bs;            // the committed bank of quotient, remainder, root
    logic        cq, cr, cs;            // cleared by rst: reads 0 until the next commit

    wire cnt16 = be[1:0] == 2'b11;
    wire w32   = be == 4'hF;
    wire div_start  = we && ((wa == 4'd0 && cnt16) || (wa[3:2] == 2'b01 && w32));
    wire sqrt_start = we && ((wa == 4'd12 && cnt16) || (wa[3:1] == 3'b111 && w32));

    // ---- divider
    typedef enum logic [1:0] {D_IDLE, D_SETUP, D_ITER, D_WAIT} dstate_t;
    dstate_t     dst;
    logic [5:0]  dcnt;              // system cycles until done
    logic [6:0]  dit;
    logic [63:0] wr_, wq;
    logic        qneg, rneg, keep_rem, den0, qz;
    // the operand patterns the divider asks about, from the write (one word compare, not one per use):
    // NUM low word 0x80000000, DEN low word 0xFFFFFFFF, DEN's words 0
    logic        n_min, d_m1, d_zl, d_zh;
    wire         w_z31 = wdata[30:0] == 31'd0;
    wire         w_o31 = &wdata[30:0];

    wire         m0  = divcnt[1:0] == 2'd0;
    wire         m2  = divcnt[1:0] == 2'd2;
    wire [63:0]  n64 = m0 ? {{32{num[31]}}, num[31:0]} : num;
    wire [63:0]  d64 = m2 ? den : {{32{den[31]}}, den[31:0]};
    wire         dneg = d64[63];
    wire         d_fin = dst == D_WAIT && dcnt == 6'd1 && tick && !div_start;

    // the one 65-bit adder: |N| (setup), R' -/+ D (iterate)
    logic [64:0] a_op, b_op, sum;
    logic        cin;
    // 32-bit mode keeps |N| in the low half and takes its dividend bits from
    // bit 31; the quotient's low 32 bits end up in wq[31:0]
    wire  [64:0] rp = {wr_, m0 ? wq[31] : wq[63]};
    always_comb begin
        if (dst == D_ITER) begin
            a_op = rp; b_op = {d64[63], d64} ^ {65{!dneg}}; cin = !dneg;
        end else begin
            a_op = '0; b_op = {1'b0, n64} ^ {65{n64[63]}}; cin = n64[63];
        end
        sum = a_op + b_op + 65'(cin);
    end
    wire [63:0] absn = sum[63:0];
    wire        ge   = !sum[64];

    // ---- square root
    typedef enum logic [1:0] {S_IDLE, S_ITER, S_WAIT} sstate_t;
    sstate_t     sst;
    logic [4:0]  scnt;
    logic [4:0]  sit;               // clks left; nibble sit-1 of the parameter
    logic [37:0] srem;              // partial remainder, signed
    logic [31:0] sacc;
    wire         s_fin = sst == S_WAIT && scnt == 5'd1 && tick && !sqrt_start;

    // Non-restoring square root. Keep the full 34-bit 4Q+1 / 4Q+3
    // trial term: truncating it to 32 bits rounds some 64-bit roots up.
    // For example sqrt(0x4000000000000001) must be 0x80000000.
    function automatic logic [37:0] sq_step(input logic [37:0] r, input logic [31:0] q,
                                            input logic [1:0] pair);
        logic [37:0] op;
        op = r[37] ? {4'd0, q, 2'b11} : ~{4'd0, q, 2'b01};
        return {r[35:0], pair} + op + 38'(!r[37]);
    endfunction
    logic [37:0] r1, r2;
    logic [31:0] q1, q2;
    logic [3:0]  nib;
    // PUMP: one step a clk2 edge, on one sq_step: the nibble's high pair at
    // the middle edge, its low pair at the next clk edge, so srem/sacc hold
    // at every clk edge what the two chained steps give (sqrt_start clears
    // them at the clk edge, as below)
    logic        sq_tg = 1'b0, sq_tq = 1'b0;
    wire         sq_mid = sq_tg != sq_tq;
    always_comb begin
        nib = param[{4'(sit - 5'd1), 2'b00} +: 4];
        r1 = sq_step(srem, sacc, PUMP && !sq_mid ? nib[1:0] : nib[3:2]); q1 = {sacc[30:0], !r1[37]};
        r2 = sq_step(r1, q1, nib[1:0]);    q2 = {q1[30:0], !r2[37]};
    end
    generate if (PUMP) begin : g_sqp
        always_ff @(posedge clk) sq_tg <= ~sq_tg;
        always_ff @(posedge clk2) begin
            sq_tq <= sq_tg;
            if (!sq_mid && !rst && sqrt_start) begin srem <= '0; sacc <= '0; end
            else if (sst == S_ITER && !rst) begin srem <= r1; sacc <= q1; end
        end
    end else begin : g_sq1
        always_ff @(posedge clk)
            if (!rst && sqrt_start) begin srem <= '0; sacc <= '0; end
            else if (!rst && sst == S_ITER) begin srem <= r2; sacc <= q2; end
    end endgenerate

    always_ff @(posedge clk) begin
        late <= 1'b0;
        if (rst) begin
            divcnt <= '0; sqrtcnt <= '0; num <= '0; den <= '0;
            n_min <= 1'b0; d_m1 <= 1'b0; d_zl <= 1'b1; d_zh <= 1'b1;
            param <= '0; dst <= D_IDLE; quot_neg <= 1'b0; remr_neg <= 1'b0; sst <= S_IDLE; dcnt <= '0; scnt <= '0;
            cq <= 1'b1; cr <= 1'b1; cs <= 1'b1;
        end else begin
            // divider
            if (dst != D_IDLE && dcnt != 6'd0 && tick) dcnt <= dcnt - 6'd1;
            case (dst)
                D_SETUP: begin
                    wq  <= absn;
                    wr_ <= '0;
                    dit <= m0 ? 7'd32 : 7'd64;
                    qneg <= n64[63] ^ dneg;
                    rneg <= n64[63];
                    keep_rem <= m0 && n_min && d_m1;
                    den0 <= d_zl && d_zh;
                    qz <= 1'b1;
                    dst <= D_ITER;
                end
                D_ITER: begin
                    wr_ <= ge ? sum[63:0] : rp[63:0];
                    wq  <= {wq[62:0], ge};
                    dit <= dit - 7'd1;
                    // the quotient's low word is 0: none of the last 32 bits was set
                    if (!(dit[6] || (dit[5] && dit[4:0] != 5'd0))) qz <= qz && !ge;
                    if (dit == 7'd1) dst <= D_WAIT;
                end
                D_WAIT: if (d_fin) begin
                    bq <= !bq; cq <= 1'b0; quot_neg <= qneg; quot_z <= qz;
                    if (!keep_rem) begin br <= !br; cr <= 1'b0; remr_neg <= rneg; remr_z <= wr_[31:0] == 32'd0; end
                    divcnt[15:14] <= {1'b0, den0};
                    dst <= D_IDLE;
                end
                default: ;
            endcase
            if ((dst == D_SETUP || dst == D_ITER) && dcnt == 6'd1 && tick) late <= 1'b1;
            // square root
            if (sst != S_IDLE && scnt != 5'd0 && tick) scnt <= scnt - 5'd1;
            case (sst)
                S_ITER: begin
                    sit <= sit - 5'd1;
                    if (sit == 5'd1) sst <= S_WAIT;
                end
                S_WAIT: if (s_fin) begin
                    bs <= !bs; cs <= 1'b0; sqrtcnt[15] <= 1'b0; sst <= S_IDLE;
                end
                default: ;
            endcase
            if (sst == S_ITER && scnt == 5'd1 && tick) late <= 1'b1;

            // register writes (a write restarts its unit)
            if (we) begin
                if (wa == 4'd0 && cnt16) divcnt <= wdata[15:0] | 16'h8000;
                if (w32) case (wa)
                    4'd4:  begin num[31:0] <= wdata; n_min <= wdata[31] && w_z31; end
                    4'd5:  num[63:32]  <= wdata;
                    4'd6:  begin den[31:0] <= wdata; d_m1 <= wdata[31] && w_o31; d_zl <= !wdata[31] && w_z31; end
                    4'd7:  begin den[63:32] <= wdata; d_zh <= !wdata[31] && w_z31; end
                    4'd14: param[31:0] <= wdata;
                    4'd15: param[63:32]<= wdata;
                    default: ;
                endcase
                if (wa[3:2] == 2'b01 && w32) divcnt[15] <= 1'b1;
                if (wa == 4'd12 && cnt16) sqrtcnt <= wdata[15:0] | 16'h8000;
                if (wa[3:1] == 3'b111 && w32) sqrtcnt[15] <= 1'b1;
            end
            if (div_start) begin
                dst  <= D_SETUP;
                dcnt <= ((wa == 4'd0 ? wdata[1:0] == 2'd0 : m0) ? 6'd18 : 6'd34) - 6'(tick);
            end
            if (sqrt_start) begin
                sst  <= S_ITER;
                scnt <= 5'd13 - 5'(tick);
                sit  <= (wa == 4'd12 ? wdata[0] : sqrtcnt[0]) ? 5'd16 : 5'd8;
            end
        end
    end

    // ---- the results RAM: word {kind, bank}, kind 0 quotient, 1 remainder, 2 root
    logic        rwe;
    logic [2:0]  rwa;
    logic [63:0] rwd, rq;
    wire  [63:0] qn = {wq[62:0], ge};   // the quotient after this iteration
    always_comb begin
        rwe = 1'b1; rwa = '0; rwd = '0;
        if (dst == D_ITER && dit == 7'd1) begin rwa = {2'd0, !bq}; rwd = {m0 ? 32'd0 : qn[63:32], qn[31:0]}; end
        else if (dst == D_WAIT)           begin rwa = {2'd1, !br}; rwd = wr_; end
        else if (sst == S_WAIT)           begin rwa = {2'd2, !bs}; rwd = {32'd0, sacc}; end
        else rwe = 1'b0;
    end
    wire         rk_r = ra[3:2] == 2'b10 && ra[1];
    wire         rk_s = ra[3:2] != 2'b10;
    generate if (PUMP) begin : g_resp
        // (the read half known at the read: the result word's half, both lanes)
        logic [31:0] rq32;
        sys_ram64w #(.AW(3)) u_res (.clk, .clk2, .we(rwe), .waddr(rwa), .wdata(rwd),
            .raddr({rk_s, rk_r, rk_s ? bs : rk_r ? br : bq}), .rhi(!rk_s && ra[0]), .rdata(rq32));
        assign rq = {rq32, rq32};
    end else begin : g_res
        sys_ram #(.W(64), .AW(3)) u_res (.clk, .we(rwe), .waddr(rwa), .wdata(rwd),
            .raddr({rk_s, rk_r, rk_s ? bs : rk_r ? br : bq}), .rdata(rq));
    end endgenerate

    // quotient and remainder words, negated here when their sign is set
    logic hi_q, neg_q, inc_q, clr_q;
    always_ff @(posedge clk) begin
        hi_q  <= !rk_s && ra[0];
        neg_q <= !rk_s && (rk_r ? remr_neg : quot_neg);
        inc_q <= !ra[0] || (rk_r ? remr_z : quot_z);
        clr_q <= rk_s ? cs : rk_r ? cr : cq;
    end
    wire [31:0] x = hi_q ? rq[63:32] : rq[31:0];
    assign res_q = clr_q ? 32'd0 : (x ^ {32{neg_q}}) + 32'(neg_q && inc_q);

    // the control bits; the operands read back from nds_sys's shadow copy
    always_comb begin
        unique case (ra)
            4'd0:  rdata = {16'd0, divcnt[15:14], 12'd0, divcnt[1:0]};   // the rest: shadow
            4'd12: rdata = {16'd0, sqrtcnt[15], 14'd0, sqrtcnt[0]};
            default: rdata = '0;
        endcase
    end
endmodule
