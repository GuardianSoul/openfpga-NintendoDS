// Ordering-regression top. Reference is the working-tree RTL with ordinary
// responses, not a historical revision. Both sides use the current firmware.
// Explicit reference control ties avoid floating inputs in this standalone top.
module tb_scpu_ordering #(parameter integer SLOTS = 24, parameter integer CTL = 0) (
    input  wire clk, reset, start,
    input  wire [31:0] rom_size,
    input  wire c_valid_n, c_valid_r, fc_busy_n, fc_busy_r, mk_valid_n, mk_valid_r,
    input  wire [31:0] c_addr_n, c_addr_r,
    input  wire [2:0] mk_err_n, mk_err_r, fc_sel_n, fc_sel_r,
    input  wire m_ready_n, m_rvalid_n, m_ready_r, m_rvalid_r,
    input  wire [31:0] m_rdata_n, m_rdata_r,
    output wire ready_n, ready_r, fail_n, fail_r, c_ready_n, c_ready_r, r_valid_n, r_valid_r, fc_send_n, fc_send_r,
    output wire m_valid_n, m_valid_r, m_write_n, m_write_r, m_quad_n, m_quad_r,
    output wire [31:0] r_data_n, r_data_r, m_wdata_n, m_wdata_r,
    output wire [23:0] m_addr_n, m_addr_r,
    output wire [3:0] m_be_n, m_be_r,
    output wire [119:0] fc_data_n, fc_data_r,
    output wire [13:0] fc_slot_n, fc_slot_r,
    output wire dg_wait_n, dg_wait_r         // the client waits for a miss
);
    `define SCPU_PORTS(sfx) \
        .clk, .reset, .start, .rom_size, .ready(ready_``sfx), .fail(fail_``sfx), \
        .c_valid(c_valid_``sfx), .c_addr(c_addr_``sfx), .c_ready(c_ready_``sfx), .r_valid(r_valid_``sfx), .r_data(r_data_``sfx), \
        .fc_send(fc_send_``sfx), .fc_data(fc_data_``sfx), .fc_busy(fc_busy_``sfx), .mk_valid(mk_valid_``sfx), .mk_err(mk_err_``sfx), \
        .m_valid(m_valid_``sfx), .m_write(m_write_``sfx), .m_quad(m_quad_``sfx), .m_addr(m_addr_``sfx), \
        .m_wdata(m_wdata_``sfx), .m_be(m_be_``sfx), .m_ready(m_ready_``sfx), .m_rvalid(m_rvalid_``sfx), .m_rdata(m_rdata_``sfx), \
        .stat_clear(1'b0), .tick_ms(1'b0), .st_lookups(), .st_cmds(), .st_blocks(), .st_wait(), .dg_wait(dg_wait_``sfx), .dg_cmd()
    reg c_pend = 0;
    reg [31:0] c_cnt = 0, c_r0 = 32'h5A5A_1234;
    wire c_take;
    always @(posedge clk) begin
        c_cnt <= c_cnt + 1;
        if (CTL != 0 && c_cnt % CTL == CTL - 1) begin
            c_pend <= 1; c_r0 <= {c_r0[30:0], c_r0[31] ^ c_r0[21] ^ c_r0[1] ^ c_r0[0]};
        end else if (c_take) c_pend <= 0;
    end
    nds_cart_scpu #(.SLOTS(SLOTS)) u_new (`SCPU_PORTS(n), .fc_sel(fc_sel_n), .fc_slot(fc_slot_n),
        .ctl_we0(), .ctl_we1(), .ctl_take(c_take), .ctl_pend(c_pend), .ctl_r0(c_r0), .ctl_st(c_r0[2:0]), .ctl_set(c_r0[13:0]));
    nds_cart_scpu_ref #(.SLOTS(SLOTS)) u_ref (`SCPU_PORTS(r), .fc_sel(fc_sel_r), .fc_slot(fc_slot_r), .ctl_we0(), .ctl_we1(), .ctl_take(), .ctl_pend(1'b0), .ctl_r0(32'd0), .ctl_st(3'd0), .ctl_set(14'd0));
endmodule
