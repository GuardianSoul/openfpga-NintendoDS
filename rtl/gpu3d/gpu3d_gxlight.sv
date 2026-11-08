// Geometry engine lighting unit (docs/geometry-engine.md "Lighting unit (LUNIT)"): the NORMAL
// command's vertex colour, melonDS's CalculateLighting bit for bit, beside the microcoded engine.
//
// It starts when the engine pops a NORMAL entry (start, with its parameter) and writes the three
// CURCOL words through the engine's register-file write port, in cycles the engine leaves it free.
// The state it reads is snooped from the engine's register-file writes (stage M):
//   - the light blocks (LIGHT + 16 i: LDIR, LRECIP, LDL, LSL, LAL), low 20 bits, in an MLAB; the
//     shininess table (SHIN, one entry a word) in an MLAB; MEMI in flops;
//   - VEC..VEC+15, the vector matrix, low 23 bits (melonDS's normal transform is 32-bit arithmetic
//     taken from bits 22..12, so higher bits never matter);
//   - CATTR bits 0..3 (the enabled lights) and USETAB bit 0.
// While busy the engine dispatches only commands that cannot change that state (gpu3d_gxeng LUNIT),
// and the microcode waits for it before the transform reads CURCOL (ucode.py SUBV).
//
// One multiplier (12 x 24 bits signed, one DSP block) and one mirror read a cycle. Each operation
// issues in one cycle (s1: the read address), reads its data and multiplies (s2), and accumulates (s3):
//   n0..n8      the normal transform, NT[c] = sx11(sum_k NRM[k] * VEC[4k + c] bits 22..12),
//               with VB[c] = MEMI[c] << 14 beside the first three
//   per enabled light, 15 issue cycles:
//     t0..t2    DOT     dot = sum_k (LDIR[k] * NT[k]) >>> 9
//     t3        LAL0    VB[0] += AL[0]
//     t4        SQ      sq = (sx11(dot + NT[2])^2 >> 10) & 0x3FF
//     t5..t7    DIFF    VB[c] += (DL[c] * sx11(dot)) & 0xFFFFF   (dot > 0)
//     t8        RECIP   shine0 = clamp(((sq * SpecRecip) >> 8) - 512)   (0 unless dot > 0)
//     t9, t10   LAL1, LAL2
//     t11       SHIN    shine = USETAB ? SHIN[shine0 >> 2] << 1 : shine0
//     t12..t14  SPEC    VB[c] += SL[c] * shine
//   then CURCOL[c] = min(VB[c] >> 14, 31) << 12 | 0xFFF, written one word a free cycle.
// VB fits 24 bits: 31 << 14 + 4 * (0xFFFFF + 961 * 511 + 492032) < 2^24.
module gpu3d_gxlight #(
    parameter logic [10:0] A_VEC    = 11'h020,
    parameter logic [10:0] A_CATTR  = 11'h0D3,
    parameter logic [10:0] A_USETAB = 11'h0E1,
    parameter logic [10:0] A_MEMI   = 11'h161,
    parameter logic [10:0] A_CURCOL = 11'h14B,
    parameter logic [10:0] A_LIGHT  = 11'h100,
    parameter logic [10:0] A_SHIN   = 11'h180,
    parameter int LDIR = 0, LRECIP = 3, LDL = 7, LSL = 10, LAL = 13,
    parameter bit LT_M10K = 1,         // the light table, VEC and the shininess table in M10K (registered reads, as in MLAB): ~5 MLAB LABs for 3 M10K
    // LT_ONE (with LT_M10K): the three tables in one 256 x 23 M10K (1 block for 3): the schedule reads at most one of
    // them a cycle (S_NT: VEC; S_LT: the light table, but SHIN at t11), each consumed the next cycle (s2), so one
    // read port serves all three: SHIN at 0..127, the light table at 128..191, VEC at 192..207
    parameter bit LT_ONE = 1
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        we,                // the engine's register-file write (stage M)
    input  logic [10:0] wa,
    input  logic [31:0] wd,
    input  logic        start,             // a NORMAL entry popped
    input  logic [29:0] nrm,               // its parameter
    input  logic        hold,              // a speculative start not yet confirmed: no CURCOL writes
    input  logic        abort,             // drop a speculative start (nothing written)
    output logic        busy,
    output logic [29:0] nr,                // the normal it works on (taken at start)
    output logic        cw,                // a CURCOL write, done in a cycle without we
    output logic [10:0] cwa,
    output logic [31:0] cwd
);
    // ---- snooped state
    // the light blocks (4 x 16 words, the fields' low 20 bits) and the shininess table (one entry a
    // word in the register file) in MLABs; MatEmission in flops
    logic [5:0]  mra;
    logic [19:0] mrd;
    logic [6:0]  sra;
    logic [7:0]  srd, srd_c;
    logic [3:0]  vra;
    logic [22:0] vrd;
    logic [1:0]  lt_rsel;                  // LT_ONE: the s1 read, 0: the light table (mra), 1: SHIN (sra), 2: VEC (vra)
    wire         lt_hit = wa[10:6] == A_LIGHT[10:6], sh_hit = wa[10:7] == A_SHIN[10:7], vec_hit = wa[10:4] == A_VEC[10:4];
    generate if (LT_M10K && LT_ONE) begin : g_one
        // one table: the read address the s1 operation needs (lt_rsel below), the write address by region
        logic [22:0] lq;
        wire  [7:0]  lwa = sh_hit ? {1'b0, wa[6:0]} : lt_hit ? {2'b10, wa[5:0]} : {4'b1100, wa[3:0]};
        wire  [7:0]  lra = lt_rsel == 2'd1 ? {1'b0, sra} : lt_rsel == 2'd2 ? {4'b1100, vra} : {2'b10, mra};
        gpu3d_ram #(.W(23), .AW(8), .STYLE("M10K")) u_ltv (.clk, .we(we && (lt_hit || sh_hit || vec_hit)), .waddr(lwa),
                                                         .wdata(wd[22:0]), .raddr(lra), .rdata(lq));
        assign mrd = lq[19:0]; assign vrd = lq; assign srd = lq[7:0]; assign srd_c = '0;
    end else begin : g_three
    // the light blocks (4 x 16 words, the fields' low 20 bits) and the shininess table (one entry a
    // word in the register file) in MLABs; MatEmission in flops
    gpu3d_ram #(.W(20), .AW(6), .STYLE(LT_M10K ? "M10K" : "MLAB")) u_lt (.clk, .we(we && lt_hit), .waddr(wa[5:0]),
                                                    .wdata(wd[19:0]), .raddr(mra), .rdata(mrd));
    // read combinationally and registered here: a 128-deep registered-read MLAB is not inferred
    // ("unsupported read-during-write behavior", #615)
    // the shininess table read straight into srd: with LT_M10K a registered-read M10K (the same value a clock on)
    if (LT_M10K) begin : g_shm
        gpu3d_ram #(.W(8), .AW(7), .STYLE("M10K")) u_sh (.clk, .we(we && sh_hit), .waddr(wa[6:0]),
                                                      .wdata(wd[7:0]), .raddr(sra), .rdata(srd));
        assign srd_c = '0;
    end else begin : g_shl
        gpu3d_lram #(.W(8), .AW(7)) u_sh (.clk, .we(we && sh_hit), .waddr(wa[6:0]),
                                          .wdata(wd[7:0]), .raddr(sra), .rdata(srd_c));
        always_ff @(posedge clk) srd <= srd_c;
    end
    gpu3d_ram #(.W(23), .AW(4), .STYLE(LT_M10K ? "M10K" : "MLAB")) u_vec (.clk, .we(we && vec_hit), .waddr(wa[3:0]),
                                                     .wdata(wd[22:0]), .raddr(vra), .rdata(vrd));
    end endgenerate
    logic [4:0]  memi [3];
    always_ff @(posedge clk)
        for (int c = 0; c < 3; c++) if (we && wa == A_MEMI + 11'(c)) memi[c] <= wd[4:0];
    logic [3:0]  lmask;
    always_ff @(posedge clk) begin
        if (we && wa == A_CATTR) lmask <= wd[3:0];
        if (we && wa == A_USETAB) ut <= wd[0];
    end

    // a light whose specular words are all zero adds nothing in SPEC, so its RECIP, SHIN and SPEC go; with the
    // dot <= 0 no DIFF adds, and without the shininess table no SPEC does either (shine is 0)
    logic [2:0]  sl_z [4];
    always_ff @(posedge clk)
        if (we && wa[10:6] == A_LIGHT[10:6] && wa[3:0] >= 4'(LSL) && wa[3:0] < 4'(LSL + 3))
            sl_z[wa[5:4]][wa[3:0] - 4'(LSL)] <= wd[9:0] == 10'd0;

    // ---- operations
    typedef enum logic [3:0] {K_NONE, K_NT, K_DOT, K_LAL, K_SQ, K_DIFF, K_RECIP, K_SHIN, K_SPEC} kind_t;

    typedef enum logic [2:0] {S_IDLE, S_DLY, S_NT, S_LT, S_FIN} st_t;
    st_t         st;
    logic [3:0]  cnt;                      // the step within S_NT (0..8), S_LT (0..14), S_DLY, S_FIN
    logic [3:0]  rm;                       // lights still to do
    logic [1:0]  li;                       // the current light

    // s1: this cycle's operation
    kind_t       k1;
    logic [1:0]  c1;                       // colour channel (S_NT: NT's channel) or DOT's component
    logic [1:0]  kn1;                      // S_NT: the normal component
    logic        m1;                       // S_NT: also VB[kn1] = MEMI[kn1] << 14 (n0..n2)
    wire  [3:0]  lnext_oh = rm & -rm;      // the lowest light still to do
    wire  [1:0]  lnext = lnext_oh[1] ? 2'd1 : lnext_oh[2] ? 2'd2 : lnext_oh[3] ? 2'd3 : 2'd0;
    wire  [5:0]  lb = {li, 4'd0};
    logic [8:0]  shine0, shine;
    logic [1:0]  nc, nk;                   // S_NT: cnt / 3 and cnt % 3, counted (no divider)
    always_comb begin
        k1 = K_NONE; c1 = 2'd0; kn1 = 2'd0; m1 = 1'b0; mra = 6'd0; vra = 4'd0; sra = shine0[8:2];
        if (st == S_NT) begin
            k1 = K_NT;
            c1 = nc;
            kn1 = nk;
            vra = {kn1, c1};                               // VEC[4k + c]
            m1 = cnt < 4'd3;
        end else if (st == S_LT) begin
            case (cnt)
                4'd0, 4'd1, 4'd2: begin k1 = K_DOT; c1 = cnt[1:0]; mra = lb + 6'(LDIR) + {4'd0, cnt[1:0]}; end
                4'd3:  begin k1 = K_LAL; c1 = 2'd0; mra = lb + 6'(LAL); end
                4'd4:  k1 = K_SQ;
                4'd5, 4'd6, 4'd7: begin k1 = K_DIFF; c1 = 2'(cnt - 4'd5); mra = lb + 6'(LDL) + {4'd0, c1}; end
                4'd8:  begin k1 = K_RECIP; mra = lb + 6'(LRECIP); end
                4'd9:  begin k1 = K_LAL; c1 = 2'd1; mra = lb + 6'(LAL) + 6'd1; end
                4'd10: begin k1 = K_LAL; c1 = 2'd2; mra = lb + 6'(LAL) + 6'd2; end
                4'd11: k1 = K_SHIN;                        // sra: shine0 >> 2
                default: begin k1 = K_SPEC; c1 = 2'(cnt - 4'd12); mra = lb + 6'(LSL) + {4'd0, c1}; end
            endcase
        end
    end

    assign lt_rsel = st == S_NT ? 2'd2 : st == S_LT && cnt == 4'd11 ? 2'd1 : 2'd0;

    // ---- sequencer
    logic [2:0] wn;                        // S_FIN: CURCOL words written
    logic       pos;                       // dot > 0
    logic       ut;
    wire        sk_sp = &sl_z[li] || (!pos && !ut);
    always_ff @(posedge clk) begin
        if (rst || abort) begin
            st <= S_IDLE; cnt <= 4'd0;
        end else case (st)
            S_IDLE: if (start) begin st <= S_DLY; cnt <= 4'd0; nr <= nrm; rm <= 4'd0; end
            // three cycles for the register-file writes before the NORMAL to land in the copies
            S_DLY:  begin
                        cnt <= cnt + 4'd1; nc <= 2'd0; nk <= 2'd0;
                        if (cnt == 4'd2) begin st <= S_NT; cnt <= 4'd0; rm <= lmask; end
                    end
            S_NT:   begin
                        cnt <= cnt + 4'd1;
                        nk <= nk == 2'd2 ? 2'd0 : nk + 2'd1;
                        if (nk == 2'd2) nc <= nc + 2'd1;
                        if (cnt == 4'd8) begin
                            cnt <= 4'd0;
                            if (rm != 4'd0) begin st <= S_LT; li <= lnext; rm <= rm & ~lnext_oh; end
                            else st <= S_FIN;
                        end
                    end
            S_LT:   begin
                        cnt <= cnt + 4'd1;
                        // (dot is in its register from cnt 5 on: DOT's last product, issued at 2, lands at 4)
                        if (cnt == 4'd5 && !pos) cnt <= sk_sp ? 4'd9 : 4'd8;
                        if (cnt == 4'd7 && sk_sp) cnt <= 4'd9;
                        if (cnt == 4'd14 || (cnt == 4'd10 && sk_sp)) begin
                            cnt <= 4'd0;
                            if (rm != 4'd0) begin li <= lnext; rm <= rm & ~lnext_oh; end
                            else st <= S_FIN;
                        end
                    end
            // two cycles for the last operations to drain, then the three writes
            S_FIN:  begin
                        if (cnt < 4'd2) cnt <= cnt + 4'd1;
                        else if (wn == 3'd3) st <= S_IDLE;
                    end
            default: st <= S_IDLE;
        endcase
    end
    assign busy = st != S_IDLE;

    // ---- s2: data, multiply
    kind_t       k2, k3;
    logic [1:0]  c2, c3, kn2, kn3;
    logic        m2;
    logic signed [10:0] ntv [3];           // NT
    logic signed [15:0] dot;
    logic [9:0]  sqv;
    wire  signed [10:0] dd  = dot[10:0];                     // diffdot = sx11(dot)
    wire  signed [15:0] d2s = dot + 16'(ntv[2]);
    wire  signed [10:0] d2  = d2s[10:0];                     // sx11(dot + NT[2])
    assign       pos = dot > 16'sd0;
    logic signed [11:0] ma;
    logic signed [23:0] mb;
    logic signed [35:0] p;
    always_comb begin
        ma = '0; mb = '0;
        case (k2)
            K_NT:    begin ma = 12'(signed'(nr[10 * kn2 +: 10])); mb = {1'b0, vrd}; end
            K_DOT:   begin ma = 12'(signed'(mrd[10:0])); mb = 24'(ntv[c2]); end
            K_SQ:    begin ma = 12'(d2); mb = 24'(d2); end
            K_DIFF:  begin ma = {2'b0, mrd[9:0]}; mb = 24'(dd); end
            K_RECIP: begin ma = {2'b0, sqv}; mb = 24'(signed'(mrd[19:0])); end
            K_SPEC:  begin ma = {2'b0, mrd[9:0]}; mb = {15'd0, shine}; end
            default: ;
        endcase
    end
    always_ff @(posedge clk) begin
        k2 <= k1; c2 <= c1; kn2 <= kn1; m2 <= m1;
        k3 <= k2; c3 <= c2; kn3 <= kn2;
        p <= ma * mb;
    end

    // ---- s3 (s2 for the operations without a multiply): accumulate
    logic [22:0] nacc;
    wire  [22:0] nsum = (kn3 == 2'd0 ? 23'd0 : nacc) + p[22:0];
    logic [23:0] vb [3];
    wire  signed [35:0] sh8 = (p >>> 8) - 36'sd512;
    wire  signed [13:0] s14 = sh8[13:0];
    logic [2:0]  vb_ld, vb_al, vb_pr;      // VB[c] = MEMI << 14, += AL, += the DIFF/SPEC product
    always_comb
        for (int c = 0; c < 3; c++) begin
            vb_ld[c] = k2 == K_NT && m2 && kn2 == 2'(c);
            vb_al[c] = k2 == K_LAL && c2 == 2'(c);
            vb_pr[c] = ((k3 == K_DIFF && pos) || k3 == K_SPEC) && c3 == 2'(c);
        end
    always_ff @(posedge clk) begin
        // the normal transform: three products a channel, mod 2^23; NT = bits 22..12, signed
        if (k3 == K_NT) begin
            nacc <= nsum;
            if (kn3 == 2'd2) ntv[c3] <= signed'(nsum[22:12]);
        end
        if (k3 == K_DOT) dot <= (c3 == 2'd0 ? 16'sd0 : dot) + 16'(p >>> 9);
        if (k3 == K_SQ) sqv <= p[19:10];
        if (k3 == K_RECIP)
            shine0 <= !pos || sh8 < 0 || s14 < 0 ? 9'd0 : s14 > 14'sd511 ? 9'd511 : s14[8:0];
        if (k2 == K_SHIN) shine <= ut ? {srd, 1'b0} : shine0;
        // one adder a channel: VB = MEMI << 14 (as 0 + it), VB += AL, VB += the DIFF/SPEC product; the schedule never
        // has two of them on one channel in a cycle (LAL at t3/t9/t10 in s2, DIFF t5..t7 and SPEC t12..t14 in s3,
        // the MEMI load in S_NT; checked below; docs/space-cg.md)
        for (int c = 0; c < 3; c++)
            if (vb_ld[c] || vb_al[c] || vb_pr[c])
                vb[c] <= (vb_ld[c] ? {5'd0, memi[c], 14'd0} : vb[c]) +
                         (vb_ld[c] ? 24'd0 : vb_al[c] ? {5'd0, mrd[18:0]} : {4'd0, p[19:0]});
    end
`ifndef SYNTHESIS
    // synthesis translate_off
    always_ff @(posedge clk)
        for (int c = 0; c < 3; c++)
            if (!rst && 2'(vb_ld[c]) + 2'(vb_al[c]) + 2'(vb_pr[c]) > 2'd1)
                $error("gpu3d_gxlight: two VB updates of channel %0d in one cycle (ld %b al %b pr %b)", c, vb_ld[c], vb_al[c], vb_pr[c]);
    // synthesis translate_on
`endif

    // ---- CURCOL writes
    wire  [9:0]  vt = vb[wn[1:0]][23:14];
    assign cw  = st == S_FIN && cnt == 4'd2 && wn != 3'd3 && !hold;
    assign cwa = A_CURCOL + {9'd0, wn[1:0]};
    assign cwd = {15'd0, vt > 10'd31 ? 5'd31 : vt[4:0], 12'hFFF};
    always_ff @(posedge clk) begin
        if (st != S_FIN) wn <= 3'd0;
        else if (cw && !we) wn <= wn + 3'd1;
    end
endmodule
