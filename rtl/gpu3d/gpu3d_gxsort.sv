// Polygon order at a swap (docs/geometry-engine.md), as GPU3D::VBlank:
// opaque polygons first, then translucent ones; each group sorted stably by
// SortKey = (YBottom << 8) | YTop, or the translucent group kept in
// submission order (manual sort, SWAP_BUFFERS bit 0).
//
// A stable sort by (ybot, ytop, index) in two steps:
//   at commit: polygon i is appended to the list of bucket {t, ytop} and
//              counted in bucket {t, ybot};
//   at sort:   the {t, ybot} counts become start positions, then the
//              {t, ytop} buckets are walked in order, each list in
//              submission order, and every polygon goes to the next position
//              of its {t, ybot} bucket. The walk is in (ytop, index) order,
//              so the result is ordered by (ybot, ytop, index).
// Manual sort: translucent polygons are placed by a walk over the indices.
// The result is written as (render position, polygon index) pairs.
// Buckets and counts carry a frame tag instead of being cleared.
module gpu3d_gxsort (
    input  logic        clk,
    input  logic        rst,
    // keys, at commit (at least 3 cycles apart)
    input  logic        ks_we,
    input  logic [10:0] ks_idx,
    input  logic [16:0] ks_key,        // {translucent, ybot, ytop}
    // sort
    input  logic        go,
    input  logic        manual,
    input  logic [11:0] n,
    output logic        busy,
    output logic        so_we,
    output logic [10:0] so_pos,
    output logic [10:0] so_idx,
    output logic        so_done
);
    logic tag;                         // frame tag of the entries being filled

    // bucket lists {t, ytop}: {tag, head, tail}
    logic        bl_we;
    logic [8:0]  bl_wa, bl_ra;
    logic [22:0] bl_wd, bl_q;
    gpu3d_ram #(.W(23), .AW(9)) u_bl (.clk, .we(bl_we), .waddr(bl_wa), .wdata(bl_wd), .raddr(bl_ra), .rdata(bl_q));
    // next pointers, {t, ybot} per polygon
    logic        nx_we;
    logic [10:0] nx_wa, nx_ra, yb_ra;
    logic [10:0] nx_wd, nx_q;
    logic [8:0]  yb_q;
    gpu3d_ram #(.W(11), .AW(11)) u_nx (.clk, .we(nx_we), .waddr(nx_wa), .wdata(nx_wd), .raddr(nx_ra), .rdata(nx_q));
    gpu3d_ram #(.W(9), .AW(11))  u_yb (.clk, .we(ks_we), .waddr(ks_idx), .wdata({ks_key[16], ks_key[15:8]}),
                                       .raddr(yb_ra), .rdata(yb_q));
    // {t, ybot} counts, then positions: {tag, value}
    logic        ct_we;
    logic [8:0]  ct_wa, ct_ra;
    logic [12:0] ct_wd, ct_q;
    gpu3d_ram #(.W(13), .AW(9)) u_ct (.clk, .we(ct_we), .waddr(ct_wa), .wdata(ct_wd), .raddr(ct_ra), .rdata(ct_q));

    typedef enum logic [3:0] {
        S_IDLE, S_C1, S_C2,            // commit: reads land, update
        S_P0, S_P1,                    // counts -> start positions
        S_B0, S_B1,                    // bucket walk
        S_E0, S_E1, S_E2, S_E3,        // one list element
        S_M0, S_M1, S_M2,              // manual sort: translucent by index
        S_DONE, S_INIT                 // S_INIT: after reset, every entry gets the other tag
    } st_t;
    st_t st;
    logic [10:0] c_idx;
    logic [16:0] c_key;
    logic [9:0]  k;
    logic [11:0] sum, s_op, rank, m, ix;
    logic [10:0] p, tl, pn;
    logic        man;
    logic [8:0]  b2;

    assign busy = st != S_IDLE && st != S_C1 && st != S_C2;
    // B1 re-tags every bucket it finds unused, so that after the tag flip at
    // the end no bucket of this or an older frame looks valid

    always_comb begin
        bl_we = 1'b0; bl_wa = {c_key[16], c_key[7:0]}; bl_wd = 23'd0;
        nx_we = 1'b0; nx_wa = bl_q[10:0]; nx_wd = c_idx;
        ct_we = 1'b0; ct_wa = {c_key[16], c_key[15:8]}; ct_wd = 13'd0;
        case (st)
            S_C2: begin
                // append c_idx to bucket {t, ytop}; count it in bucket {t, ybot}
                bl_we = 1'b1;
                if (bl_q[22] == tag) begin
                    bl_wd = {tag, bl_q[21:11], c_idx};
                    nx_we = 1'b1;
                end else
                    bl_wd = {tag, c_idx, c_idx};
                ct_we = 1'b1;
                ct_wd = {tag, (ct_q[12] == tag) ? ct_q[11:0] + 12'd1 : 12'd1};
            end
            S_P1: begin ct_we = 1'b1; ct_wa = k[8:0] - 9'd1; ct_wd = {tag, sum}; end
            S_B1: if (bl_q[22] != tag) begin bl_we = 1'b1; bl_wa = k[8:0]; bl_wd = {tag, 22'd0}; end
            S_INIT: begin
                bl_we = 1'b1; bl_wa = k[8:0]; bl_wd = {~tag, 22'd0};
                ct_we = 1'b1; ct_wa = k[8:0]; ct_wd = {~tag, 12'd0};
            end
            S_E3: begin ct_we = 1'b1; ct_wa = b2; ct_wd = {tag, ct_q[11:0] + 12'd1}; end
            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        so_we <= 1'b0; so_done <= 1'b0;
        if (rst) begin
            st <= S_INIT; tag <= 1'b0; k <= 10'd0;
            bl_ra <= 9'd0; ct_ra <= 9'd0; nx_ra <= 11'd0; yb_ra <= 11'd0;
        end else begin
            case (st)
                S_IDLE: begin
                    if (ks_we) begin
                        c_idx <= ks_idx; c_key <= ks_key;
                        bl_ra <= {ks_key[16], ks_key[7:0]};
                        ct_ra <= {ks_key[16], ks_key[15:8]};
                        st <= S_C1;
                    end else if (go) begin
                        man <= manual; m <= n; sum <= 12'd0; k <= 10'd0;
                        ct_ra <= 9'd0; st <= S_P0;
                    end
                end
                S_C1: st <= S_C2;
                S_C2: st <= S_IDLE;
                // start[b] = sum of the counts before b (other tags count 0)
                S_P0: begin ct_ra <= 9'd1; k <= 10'd1; st <= S_P1; end
                S_P1: begin
                    sum <= sum + ((ct_q[12] == tag) ? ct_q[11:0] : 12'd0);
                    if (k == 10'd256) s_op <= sum + ((ct_q[12] == tag) ? ct_q[11:0] : 12'd0);
                    if (k == 10'd512) begin
                        k <= 10'd0; bl_ra <= 9'd0; st <= S_B0;
                    end else begin
                        k <= k + 10'd1; ct_ra <= k[8:0] + 9'd1;
                    end
                end
                // walk the buckets {t, ytop}; t = 1 only without manual sort
                S_B0: st <= S_B1;
                S_B1: begin
                    if (bl_q[22] == tag && !(k[8] && man)) begin
                        p <= bl_q[21:11]; tl <= bl_q[10:0];
                        nx_ra <= bl_q[21:11]; yb_ra <= bl_q[21:11];
                        st <= S_E0;
                    end else if (k == 10'd511) begin
                        ix <= 12'd0; rank <= 12'd0; yb_ra <= 11'd0;
                        st <= (man && m != 12'd0) ? S_M0 : S_DONE;
                    end else begin
                        k <= k + 10'd1; bl_ra <= k[8:0] + 9'd1; st <= S_B0;
                    end
                end
                S_E0: st <= S_E1;
                S_E1: begin b2 <= yb_q; ct_ra <= yb_q; pn <= nx_q; st <= S_E2; end
                S_E2: st <= S_E3;
                S_E3: begin
                    so_we <= 1'b1; so_pos <= ct_q[10:0]; so_idx <= p;
                    if (p == tl) begin
                        if (k == 10'd511) begin
                            ix <= 12'd0; rank <= 12'd0; yb_ra <= 11'd0;
                            st <= (man && m != 12'd0) ? S_M0 : S_DONE;
                        end else begin
                            k <= k + 10'd1; bl_ra <= k[8:0] + 9'd1; st <= S_B0;
                        end
                    end else begin
                        p <= pn; nx_ra <= pn; yb_ra <= pn; st <= S_E0;
                    end
                end
                // manual sort: translucent polygons in submission order after the opaque ones
                S_M0: st <= S_M1;
                S_M1: st <= S_M2;
                S_M2: begin
                    if (yb_q[8]) begin
                        so_we <= 1'b1; so_pos <= s_op[10:0] + rank[10:0]; so_idx <= ix[10:0];
                        rank <= rank + 12'd1;
                    end
                    if (ix + 12'd1 == m) st <= S_DONE;
                    else begin ix <= ix + 12'd1; yb_ra <= ix[10:0] + 11'd1; st <= S_M0; end
                end
                S_DONE: begin so_done <= 1'b1; tag <= ~tag; st <= S_IDLE; end
                S_INIT: begin k <= k + 10'd1; if (k == 10'd511) st <= S_IDLE; end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
