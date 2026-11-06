// Geometry engine vertex-finish unit (docs/geometry-engine.md, "Fixed-function hot spots", item D):
// the per-vertex final colour, pre-packed beat words and polygon bounds of the viewport loop
// (ucode.py VPV: fcol, pack_words, BVX), bit for bit, beside the microcoded engine.
//
// It follows one viewport vertex at a time, from the engine's register-file traffic:
//   - VPV's VARM wait arms it, and the next write of a group's W (word G_W, VPV's next instruction)
//     starts it and names the group (other code writes G_W too: reset clears the groups);
//   - the vertex's colour words G_C+0..2 and texture coordinates G_T+0..1, which VPV reads on
//     otherwise idle ports (port A or B, data in stage O), give the beat words:
//       fc_c = (G_C+c >>> 12) == 0 ? 0 : ((G_C+c >>> 12) << 4 | 15) & 0x1FF
//       W1 = r << 25, W2 = r >> 7 | g << 2 | b << 11 | s << 20, W3 = ((s & 0xFFFF) | t << 16) >> 12
//   - VPV's write of G_FY (after G_FX) gives the bounds, with the list index IDX / IDXB:
//       KT = min(KT, y << 4 | IDX), KB = max(KB, (y << 9 | x) << 4 | IDXB)
//     and WOR |= w, DEG |= w == 0 already at the G_W write
// KT, KB, WOR and DEG are kept here as well as in the register file: the engine's own writes of them
// (VPORT's start values, the reused vertices' BVX, BOUNDS) are snooped. The unit's results go through
// the engine's write port in cycles the engine doesn't write. The microcode waits on busy before it
// starts a vertex or a polygon's viewport pass, and before BOUNDS.
module gpu3d_gxvfin #(
    parameter logic [10:0] A_KT = 11'h0, A_KB = 11'h0, A_WOR = 11'h0, A_DEG = 11'h0,
    parameter logic [10:0] A_IDX = 11'h0, A_IDXB = 11'h0,
    // vertex groups: GRP + 16 g, g < 32 (ucode.py), and the words of a group
    parameter int G_C = 4, G_W = 7, G_T = 8, G_FX = 10, G_FY = 11, G_W1 = 12,
    // 0 (VFIN-lite, gpu3d_gxeng VFIN = 2): the colour and beat words only; the bounds stay in microcode
    parameter bit BOUNDS = 1
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        arm,               // VPV's VARM wait fell through: its next instruction writes G_W
    input  logic        we,                // the engine's register-file write (stage M)
    input  logic [10:0] wa,
    input  logic [31:0] wd,
    input  logic [10:0] ra_o,              // the register-file read addresses of the data in stage O
    input  logic [31:0] qa,
    input  logic [9:0]  rb_o,
    input  logic [31:0] qb,
    input  logic        wfree,             // the engine's write port is free this cycle (no engine or LUNIT write)
    output logic        busy,
    output logic        cw,                // a result write, in a free cycle
    output logic [10:0] cwa,
    output logic [31:0] cwd
);
    function automatic logic in_grp(input logic [10:0] a, input logic [4:0] g, input int off);
        return a[10:9] == 2'b01 && a[8:4] == g && a[3:0] == 4'(off);
    endfunction

    // ---- snooped polygon state
    logic [3:0]  idx, idxb;
    logic [11:0] kt;                   // min(y << 4 | i): y < 256
    logic [20:0] kb;                   // max((y << 9 | x) << 4 | 15 - i)
    logic [23:0] w_or;
    logic        deg;

    // ---- the vertex
    typedef enum logic [1:0] {V_IDLE, V_ARM, V_RUN, V_WB} vst_t;
    vst_t        vst;
    logic [4:0]  g;                    // its group
    logic [4:0]  got;                  // r, g, b, s, t captured
    logic [4:0]  fv [3];               // (G_C+c >>> 12)[4:0]
    logic [2:0]  fnz;                  // (G_C+c >>> 12) != 0
    logic [15:0] ts, tt;
    logic [8:0]  fx;
    logic        bnd;                  // the bounds are in (G_FY written)
    logic [6:0]  wq;                   // results still to write: W1, W2, W3, KT, KB, WOR, DEG

    wire wg = we && wa[10:9] == 2'b01 && wa[3:0] == 4'(G_W);    // VPV: a vertex's W
    function automatic logic [8:0] fcol(input int c);
        return fnz[c] ? {fv[c], 4'hF} : 9'd0;
    endfunction
    wire [8:0]  fr = fcol(0), fg = fcol(1), fb = fcol(2);
    wire [31:0] w1 = {fr[6:0], 25'd0};
    wire [31:0] w2 = {ts[11:0], fb, fg, fr[8:7]};
    wire [31:0] w3 = {12'd0, tt, ts[15:12]};

    // the next result in order, written when the engine leaves the port free
    logic [2:0]  wsel;
    always_comb begin
        wsel = 3'd7;
        for (int i = 6; i >= 0; i--) if (wq[i] && (BOUNDS || i < 3)) wsel = 3'(i);
    end
    always_comb begin
        cwa = '0; cwd = '0;
        unique case (wsel)
            3'd0: begin cwa = {2'b01, g, 4'(G_W1)};     cwd = w1; end
            3'd1: begin cwa = {2'b01, g, 4'(G_W1 + 1)}; cwd = w2; end
            3'd2: begin cwa = {2'b01, g, 4'(G_W1 + 2)}; cwd = w3; end
            3'd3: begin cwa = A_KT;  cwd = {20'd0, kt}; end
            3'd4: begin cwa = A_KB;  cwd = {11'd0, kb}; end
            3'd5: begin cwa = A_WOR; cwd = {8'd0, w_or}; end
            3'd6: begin cwa = A_DEG; cwd = {31'd0, deg}; end
            default: ;
        endcase
    end
    assign cw = wsel != 3'd7 && wfree;
    assign busy = vst != V_IDLE;

    // the colour and texture coordinate reads, either port: from the trigger cycle on (the instruction
    // after VPV's G_W write has its read data in O while that write is in M)
    wire        act = wg && vst == V_ARM || vst == V_RUN;
    wire [4:0]  gc = vst == V_ARM ? wa[8:4] : g;
    logic [4:0] got_n;
    always_comb begin
        got_n = '0;
        for (int k = 0; k < 2; k++) begin
            logic [10:0] a;
            a = k == 0 ? ra_o : {1'b0, rb_o};
            for (int c = 0; c < 3; c++) if (act && in_grp(a, gc, G_C + c)) got_n[c] = 1'b1;
            if (act && in_grp(a, gc, G_T))     got_n[3] = 1'b1;
            if (act && in_grp(a, gc, G_T + 1)) got_n[4] = 1'b1;
        end
    end
    always_ff @(posedge clk)
        for (int k = 0; k < 2; k++) begin
            logic [10:0] a;
            logic [31:0] q;
            a = k == 0 ? ra_o : {1'b0, rb_o};
            q = k == 0 ? qa : qb;
            for (int c = 0; c < 3; c++)
                if (act && in_grp(a, gc, G_C + c)) begin fv[c] <= q[16:12]; fnz[c] <= q[31:12] != 20'd0; end
            if (act && in_grp(a, gc, G_T))     ts <= q[15:0];
            if (act && in_grp(a, gc, G_T + 1)) tt <= q[15:0];
        end

    always_ff @(posedge clk) begin
        // the engine's writes of the polygon state (the unit's own results equal what it holds)
        if (BOUNDS && we) begin
            if (wa == A_IDX)  idx  <= wd[3:0];
            if (wa == A_IDXB) idxb <= wd[3:0];
            if (wa == A_KT)   kt   <= wd[11:0];
            if (wa == A_KB)   kb   <= wd[20:0];
            if (wa == A_WOR)  w_or  <= wd[23:0];
            if (wa == A_DEG)  deg  <= wd[0];
        end
        if (rst) begin vst <= V_IDLE; wq <= '0; end
        else unique case (vst)
            V_IDLE: if (arm) vst <= V_ARM;
            V_ARM: if (wg) begin
                g <= wa[8:4]; bnd <= 1'b0; vst <= V_RUN;
                if (BOUNDS) begin
                    w_or <= w_or | wd[23:0];    // W is known here: no copy of it is kept
                    deg <= deg | (wd[23:0] == 24'd0);
                end
                got <= got_n;
            end
            V_RUN: begin
                got <= got | got_n;
                if (BOUNDS && we && in_grp(wa, g, G_FX)) fx <= wd[8:0];
                if (BOUNDS && we && in_grp(wa, g, G_FY)) begin
                    // the bounds (y is the word being written; the list index is IDX / IDXB)
                    if ({wd[7:0], idx} < kt) kt <= {wd[7:0], idx};
                    if ({wd[7:0], fx, idxb} > kb) kb <= {wd[7:0], fx, idxb};
                    bnd <= 1'b1;
                end
                if (&got && (bnd || !BOUNDS)) begin wq <= BOUNDS ? 7'h7F : 7'h07; vst <= V_WB; end
            end
            V_WB: begin
                if (cw) wq[wsel] <= 1'b0;
                if (wq == 7'(1 << wsel) && cw) vst <= V_IDLE;
            end
            default: vst <= V_IDLE;
        endcase
    end
`ifndef SYNTHESIS
    // synthesis translate_off
    int bcnt = 0;
    always_ff @(posedge clk) begin
        bcnt <= busy ? bcnt + 1 : 0;
        if (bcnt == 400) $display("gxvfin: busy 400 clocks: state %0d group %0d got %b bounds %b queue %b", vst, g, got, bnd, wq);
    end
    // synthesis translate_on
`endif
endmodule
