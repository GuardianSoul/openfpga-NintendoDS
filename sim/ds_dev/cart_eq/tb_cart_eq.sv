// nds_cart equivalence top: the working tree's card interface (u_new)
// against a reference revision (nds_cart_ref, u_ref) on the same register
// traffic; each has its own ROM-cache and save-memory answers, driven by
// cart_eq.cpp.
module tb_cart_eq (
    input  logic        clk, rst, tick, owner7, raw, ir,
    input  logic [2:0]  save_type,
    input  logic [20:0] sv_loaded,
    input  logic [31:0] rom_size,
    input  logic        io_req, io_cpu, io_we,
    input  logic [3:0]  io_be,
    input  logic [2:0]  io_reg,
    input  logic [31:0] io_wdata,
    input  logic        cr_ack_n, cr_rvalid_n, cr_ack_r, cr_rvalid_r,
    input  logic [31:0] cr_rdata_n, cr_rdata_r,
    input  logic        sv_ack_n, sv_ack_r,
    input  logic [31:0] sv_rdata_n, sv_rdata_r,
    output logic [127:0] o_new, o_ref
);
    logic [31:0] io_rdata_n, io_rdata_r, sv_wdata_n, sv_wdata_r;
    logic irq_n, irq_r, drq_n, drq_r, cr_req_n, cr_req_r, sv_req_n, sv_req_r, sv_we_n, sv_we_r;
    logic [31:4] cr_addr_n, cr_addr_r;
    logic [19:2] sv_addr_n, sv_addr_r;
    logic [3:0] sv_be_n, sv_be_r;
    nds_cart u_new (.clk, .rst, .tick, .owner7, .raw, .ir, .save_type, .sv_loaded, .rom_size,
        .io_req, .io_cpu, .io_we, .io_be, .io_reg, .io_wdata, .io_rdata(io_rdata_n), .irq(irq_n), .drq(drq_n),
        .cr_req(cr_req_n), .cr_addr(cr_addr_n), .cr_ack(cr_ack_n), .cr_rvalid(cr_rvalid_n), .cr_rdata(cr_rdata_n),
        .sv_req(sv_req_n), .sv_we(sv_we_n), .sv_addr(sv_addr_n), .sv_be(sv_be_n), .sv_wdata(sv_wdata_n),
        .sv_ack(sv_ack_n), .sv_rdata(sv_rdata_n));
    nds_cart_ref u_ref (.clk, .rst, .tick, .owner7, .raw, .ir, .save_type, .sv_loaded, .rom_size,
        .io_req, .io_cpu, .io_we, .io_be, .io_reg, .io_wdata, .io_rdata(io_rdata_r), .irq(irq_r), .drq(drq_r),
        .cr_req(cr_req_r), .cr_addr(cr_addr_r), .cr_ack(cr_ack_r), .cr_rvalid(cr_rvalid_r), .cr_rdata(cr_rdata_r),
        .sv_req(sv_req_r), .sv_we(sv_we_r), .sv_addr(sv_addr_r), .sv_be(sv_be_r), .sv_wdata(sv_wdata_r),
        .sv_ack(sv_ack_r), .sv_rdata(sv_rdata_r));
    // what a read answers: ROMCTRL only bits 31 and 23, the data port only while DRQ was up
    logic        rq_rd = 1'b0, rq_ready = 1'b0;
    logic [2:0]  rq_reg = 3'd0;
    // (past the file's end the reference shows FFFFFFFF only for a line's first word, then stale words; the new one all ones)
    logic        rq_past = 1'b0;
    always_ff @(posedge clk) begin rq_rd <= io_req && !io_we; rq_reg <= io_reg; rq_ready <= drq_r; rq_past <= u_new.r_past && u_new.kind == 2'd0; end
    wire [31:0] rd_mask = !rq_rd ? 32'hFFFF_FFFF : rq_reg == 3'd1 ? 32'h8080_0000 : (rq_reg == 3'd4 && (!rq_ready || rq_past)) ? 32'd0 : 32'hFFFF_FFFF;
    // {io_rdata 32, cr_addr 28, sv_wdata 32, sv_addr 18, sv_be 4, irq, drq, cr_req, sv_req, sv_we, pad 9}
    // (the request fields only while they are up: the memory models read them from here)
    assign o_new = {io_rdata_n & rd_mask, cr_req_n ? cr_addr_n : 28'd0, sv_req_n && sv_we_n ? sv_wdata_n : 32'd0,
                    sv_req_n ? sv_addr_n : 18'd0, sv_req_n ? sv_be_n : 4'd0, irq_n, drq_n, cr_req_n, sv_req_n, sv_req_n && sv_we_n, 9'd0};
    assign o_ref = {io_rdata_r & rd_mask, cr_req_r ? cr_addr_r : 28'd0, sv_req_r && sv_we_r ? sv_wdata_r : 32'd0,
                    sv_req_r ? sv_addr_r : 18'd0, sv_req_r ? sv_be_r : 4'd0, irq_r, drq_r, cr_req_r, sv_req_r, sv_req_r && sv_we_r, 9'd0};
    int dbg = 0;
    always_ff @(posedge clk) begin
        if ($test$plusargs("dbgw") && sv_ack_n && sv_req_n && !u_new.sv_er && sv_we_n) $display("w a %h be %h d %h cmd %h pos %0d", sv_addr_n, sv_be_n, sv_wdata_n, u_new.sp_cmd, u_new.sp_pos);
        if ($test$plusargs("dbg") && o_new != o_ref && dbg < 3) begin dbg <= dbg + 1;
            $display("new %h ref %h type %0d kind %0d sz %h ref er_a %h sv %h req %b er %b | new k %h er_a %h sv %h req %b er %b last %b cmd %h lw %h sq %0d a %h rs %0d kind %0d ra %h rd %b reg %0d", o_new, o_ref, save_type, u_new.sv_kind, u_new.sz_w, u_ref.er_a, sv_addr_r, sv_req_r, u_ref.sv_er, u_new.er_k, u_new.er_a, sv_addr_n, sv_req_n, u_new.sv_er, u_new.er_last, u_new.sp_cmd, u_new.sv_lw, u_new.sp_pos, u_new.sp_a, u_new.rs, u_new.kind, u_new.raddr, rq_rd, rq_reg);
        end
    end
endmodule
