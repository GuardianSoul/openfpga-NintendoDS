// The ARM7's two ports without caches (docs/phase2-integration.md, "ARM7
// port"): nds_arm7_port's interface, selected by nds_top's ARM7_CACHE = 0
// for area. The pipeline asks in one cycle and takes the answer (ok + data)
// in the next; an access it does not get answered is replayed.
//
// Boot ROM (0x00008000-0x00009FFF), M10K, answered the next cycle; the
// fabric uses its port B in cycles without an ARM7 data access (d_boot).
//
// Everything else goes through one slow path, one access at a time, either
// to the external SRAM (BIOS7, shared WRAM, ARM7 WRAM: x_*, at the SRAM
// addresses nds_arm7_port lists) or to the bus fabric (f_*):
//   - a store is posted into a one-entry buffer and answered ok at once
//     (refused while the buffer is full); BIOS7 stores are dropped;
//   - a load is refused, read, and its word kept in a buffer for the replay
//     of the same address;
//   - a fetch is refused and its 16-byte line read (four word reads) into
//     one of two line buffers, which then answer every fetch in them. A
//     write to a buffered line by the ARM7 or anyone else (wr_* on the
//     fabric, inv on the SRAM) invalidates it.
//   Reads wait for the store buffer to drain, so they never pass an older
//   store; the SRAM arbiter lets the ARM7's posted store go before others'
//   reads (x_stores).
module nds_arm7_port_min #(
    // 1: the boot ROM (0x8000-0x9FFF) is read through the fabric, not ports
    // A/B (cpu_domain with CPU_FAST: the ROM stays on clk_sys)
    parameter int BOOT_FAB = 0
) (
    input  logic        clk,
    input  logic        rst,
    input  logic [1:0]  wramcnt,
    // pipeline ports
    input  logic        i_req,
    input  logic [31:0] i_addr,
    output logic [31:0] i_rdata,
    output logic        i_ok,
    input  logic        d_req,
    input  logic        d_we,
    input  logic [3:0]  d_be,
    input  logic [31:0] d_addr,
    input  logic [31:0] d_wdata,
    output logic [31:0] d_rdata,
    output logic        d_ok,
    // boot ROM: fetch on port A, data on port B
    output logic [10:0] ib_addr,
    input  logic [31:0] i_boot_q,
    output logic [10:0] db_addr,
    output logic        d_boot,
    input  logic [31:0] d_boot_q,
    // SRAM (through nds_fr_arb): request held until done
    output logic        x_req,
    output logic        x_we,
    output logic [17:2] x_addr,
    output logic [3:0]  x_be,
    output logic [31:0] x_wdata,
    output logic        x_stores,
    input  logic        x_done,
    input  logic [31:0] x_rdata,
    input  logic        inv,
    input  logic [17:2] inv_addr,
    // bus fabric (request held until ack; read data with ack)
    output logic        f_req,
    output logic        f_we,
    output logic [31:0] f_addr,
    output logic [3:0]  f_be,
    output logic [31:0] f_wdata,
    input  logic        f_ack,
    input  logic [31:0] f_rdata,
    input  logic        wr_mon,
    input  logic [31:0] wr_addr
);
    // region: 1 boot ROM, 2 SRAM, 0 fabric (as nds_arm7_port)
    function automatic logic [1:0] reg_of(input logic [31:0] a);
        if (a[31:14] == 18'd0) return 2'd2;
        if (a[31:13] == 19'h00004) return BOOT_FAB ? 2'd0 : 2'd1;
        if (a[31:24] == 8'h03) return 2'd2;
        return 2'd0;
    endfunction
    function automatic logic [17:0] xa_of(input logic [31:0] a, input logic [1:0] wc);
        if (a[31:24] != 8'h03) return {4'b0110, a[13:0]};
        if (a[23] || wc == 2'd0) return {2'b00, a[15:0]};
        case (wc)
            2'd1: return {3'b010, 1'b0, a[13:0]};
            2'd2: return {3'b010, 1'b1, a[13:0]};
            default: return {3'b010, a[14:0]};
        endcase
    endfunction

    wire [1:0] ireg = reg_of(i_addr);
    wire [1:0] dreg = reg_of(d_addr);
    wire [17:0] ixa = xa_of(i_addr, wramcnt);
    wire [17:0] dxa = xa_of(d_addr, wramcnt);
    assign ib_addr = i_addr[12:2];
    assign db_addr = d_addr[12:2];
    assign d_boot  = d_req && dreg == 2'd1;

    // ---- slow path state
    logic        wb_v, wb_x;            // posted store (to the SRAM?)
    logic [31:0] wb_a, wb_d;
    logic [17:2] wb_xa;
    logic [3:0]  wb_be;
    logic        rp_v, rp_i, rp_x;      // read: fetch line (1) or data word (0); from the SRAM?
    logic [31:0] rp_a;
    logic [3:0]  rp_be;                 // a data read's byte enables (I/O reads with side effects)
    logic [17:2] rp_xa;                 // its SRAM word (rp_x; a fetch: the line's)
    logic [1:0]  rp_k;
    logic        rb_v;                  // finished data read
    logic [31:0] rb_a, rb_d;
    logic [1:0]  il_v;                  // fetch lines
    logic [31:4] il_a [2];
    logic        il_new;
    logic        busy, busy_w, busy_x;  // access in flight (the store? on the SRAM?)
    logic [31:0] il_q;

    logic        ia_v, ia_ok, da_v, da_ok;
    logic [1:0]  ia_r, da_r;
    logic [31:0] da_d;
    logic        prot_q;

    wire il_hit0 = il_v[0] && il_a[0] == i_addr[31:4];
    wire il_hit1 = il_v[1] && il_a[1] == i_addr[31:4];
    wire i_pend  = rp_v && rp_i && rp_a[31:4] == i_addr[31:4];
    wire d_hit   = rb_v && rb_a[31:2] == d_addr[31:2];
    wire done    = busy && (busy_x ? x_done : f_ack);
    wire [31:0] rdata_in = busy_x ? x_rdata : f_rdata;

    logic [31:0] last_fetch;

    always_ff @(posedge clk) begin
        ia_v <= i_req; ia_r <= ireg; ia_ok <= 1'b0;
        da_v <= d_req; da_r <= dreg; da_ok <= 1'b0;
        prot_q <= dreg == 2'd2 && d_addr[31:14] == 18'd0 && last_fetch >= 32'h4000;
        if (rst) begin
            wb_v <= 1'b0; rp_v <= 1'b0; busy <= 1'b0; busy_w <= 1'b0; busy_x <= 1'b0;
            rb_v <= 1'b0; il_v <= 2'b00; il_new <= 1'b0; ia_v <= 1'b0; da_v <= 1'b0;
            last_fetch <= 32'd0;
        end else begin
            if (i_req) last_fetch <= i_addr;
            // completion
            if (done) begin
                busy <= 1'b0;
                if (busy_w) wb_v <= 1'b0;
                else if (!rp_i) begin
                    rp_v <= 1'b0; rb_v <= 1'b1; rb_a <= rp_a; rb_d <= rdata_in;
                end else begin
                    rp_k <= rp_k + 2'd1;
                    if (rp_k == 2'd3) begin
                        rp_v <= 1'b0;
                        il_v[il_new] <= 1'b1; il_a[il_new] <= rp_a[31:4];
                        il_new <= !il_new;
                    end
                end
            end
            // start the next access: the store first
            if (!busy || done) begin
                if (wb_v && !(done && busy_w)) begin busy <= 1'b1; busy_w <= 1'b1; busy_x <= wb_x; end
                else if (rp_v && !(done && !busy_w && (!rp_i || rp_k == 2'd3))) begin
                    busy <= 1'b1; busy_w <= 1'b0; busy_x <= rp_x;
                end
            end
            // data access
            if (d_req) begin
                if (dreg == 2'd1) da_ok <= 1'b1;
                else if (d_we) begin
                    if (!wb_v) begin
                        // a BIOS7 store is answered and dropped
                        wb_v <= !(dreg == 2'd2 && d_addr[31:14] == 18'd0);
                        wb_x <= dreg == 2'd2; wb_xa <= dxa[17:2];
                        wb_a <= d_addr; wb_d <= d_wdata; wb_be <= d_be; da_ok <= 1'b1;
                    end
                end else if (d_hit) begin
                    da_ok <= 1'b1; da_d <= rb_d; rb_v <= 1'b0;
                end else if (!rp_v && !wb_v) begin
                    rb_v <= 1'b0;
                    rp_v <= 1'b1; rp_i <= 1'b0; rp_a <= d_addr; rp_be <= d_be;
                    rp_x <= dreg == 2'd2; rp_xa <= dxa[17:2];
                end
            end
            // fetch (the data side wins the read slot)
            if (i_req) begin
                if (ireg == 2'd1) ia_ok <= 1'b1;
                else if (il_hit0 || il_hit1) begin
                    ia_ok <= 1'b1;
                    il_new <= !il_hit1;
                end else if (!rp_v && !wb_v && !(d_req && dreg != 2'd1) && !i_pend) begin
                    rp_v <= 1'b1; rp_i <= 1'b1; rp_a <= {i_addr[31:4], 4'd0}; rp_k <= 2'd0;
                    rp_x <= ireg == 2'd2; rp_xa <= {ixa[17:4], 2'b00};
                    il_v[il_new] <= 1'b0;
                end
            end
            // writes invalidate the fetch lines they hit: the fabric's by
            // address, the SRAM's others' writes (their CPU address is not
            // known here) all lines, the ARM7's own SRAM stores by address
            if (wr_mon) begin
                if (il_a[0] == wr_addr[31:4]) il_v[0] <= 1'b0;
                if (il_a[1] == wr_addr[31:4]) il_v[1] <= 1'b0;
            end
            if (inv) il_v <= 2'b00;
            if (done && busy_w && busy_x) begin
                if (il_a[0] == wb_a[31:4]) il_v[0] <= 1'b0;
                if (il_a[1] == wb_a[31:4]) il_v[1] <= 1'b0;
            end
        end
    end

    gpu2d_mlab #(.W(32), .AW(3)) u_il (.clk, .we(done && !busy_w && rp_i), .waddr({il_new, rp_k}),
        .wdata(rdata_in), .raddr({il_hit1, i_addr[3:2]}), .rdata(il_q));

    assign x_req    = busy && busy_x;
    assign x_we     = busy_w;
    assign x_addr   = busy_w ? wb_xa : rp_i ? {rp_xa[17:4], rp_k} : rp_xa;
    assign x_be     = busy_w ? wb_be : 4'hF;
    assign x_wdata  = wb_d;
    assign x_stores = wb_v && wb_x;

    assign f_req   = busy && !busy_x;
    assign f_we    = busy_w;
    assign f_addr  = busy_w ? wb_a : rp_i ? {rp_a[31:4], rp_k, 2'b00} : rp_a;
    // a data read goes out with the load's own byte enables (a 16-bit read
    // of a register with read side effects must stay 16 bits); fetch lines
    // read whole words
    assign f_be    = busy_w ? wb_be : rp_i ? 4'hF : rp_be;
    assign f_wdata = wb_d;

    always_comb begin
        unique case (ia_r)
            2'd1:    i_rdata = i_boot_q;
            default: i_rdata = il_q;
        endcase
        unique case (da_r)
            2'd1:    d_rdata = d_boot_q;
            2'd2:    d_rdata = prot_q ? 32'hFFFF_FFFF : da_d;
            default: d_rdata = da_d;
        endcase
    end
    assign i_ok = ia_v && ia_ok;
    assign d_ok = da_v && da_ok;
endmodule
