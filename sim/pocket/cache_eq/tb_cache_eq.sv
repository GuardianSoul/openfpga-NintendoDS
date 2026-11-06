// nds_cart_cache equivalence top: the working tree's cache (u_new) against
// a reference revision (nds_cart_cache_ref, u_ref) on the same client,
// fetch-busy and marker inputs; each has its own SDRAM, driven by
// cache_eq.cpp. Small SLOTS so that eviction and CLOCK wrap are exercised.
module tb_cache_eq #(parameter integer SLOTS = 24) (
    input  wire         clk, reset, start,
    input  wire [31:0]  rom_size,
    input  wire         c_valid,
    input  wire [31:0]  c_addr,
    input  wire         fc_busy_n, fc_busy_r, mk_valid,
    input  wire [2:0]   mk_err,
    input  wire         m_ready_n, m_rvalid_n, m_ready_r, m_rvalid_r,
    input  wire [31:0]  m_rdata_n, m_rdata_r,
    output wire [255:0] o_new, o_ref
);
    `define CACHE_PORTS(sfx) \
        .clk, .reset, .start, .rom_size, .ready(ready_``sfx), .fail(fail_``sfx), .init_capped(), \
        .c_valid, .c_addr, .c_ready(c_ready_``sfx), .r_valid(r_valid_``sfx), .r_data(r_data_``sfx), \
        .fc_send(fc_send_``sfx), .fc_data(fc_data_``sfx), .fc_busy(fc_busy_``sfx), .mk_valid, .mk_err, \
        .m_valid(m_valid_``sfx), .m_write(m_write_``sfx), .m_quad(m_quad_``sfx), .m_addr(m_addr_``sfx), \
        .m_wdata(m_wdata_``sfx), .m_be(m_be_``sfx), .m_ready(m_ready_``sfx), .m_rvalid(m_rvalid_``sfx), \
        .m_rdata(m_rdata_``sfx), .stat_clear(1'b0), .tick_ms(1'b0), \
        .st_lookups(), .st_fast(), .st_cmds(), .st_blocks(), .st_evict(), .st_wait(), .st_errors(), .st_spans(), .st_marks()
    wire ready_n, fail_n, c_ready_n, r_valid_n, fc_send_n, m_valid_n, m_write_n, m_quad_n;
    wire ready_r, fail_r, c_ready_r, r_valid_r, fc_send_r, m_valid_r, m_write_r, m_quad_r;
    wire [31:0] r_data_n, r_data_r, m_wdata_n, m_wdata_r;
    wire [119:0] fc_data_n, fc_data_r;
    wire [23:0] m_addr_n, m_addr_r;
    wire [3:0] m_be_n, m_be_r;
    nds_cart_cache     #(.SLOTS(SLOTS)) u_new (`CACHE_PORTS(n));
    nds_cart_cache_ref #(.SLOTS(SLOTS)) u_ref (`CACHE_PORTS(r));
    assign o_new = {fc_data_n, m_addr_n, m_wdata_n, m_be_n, m_valid_n, m_write_n, m_quad_n,
                    r_data_n, ready_n, fail_n, c_ready_n, r_valid_n, fc_send_n, 36'd0};
    assign o_ref = {fc_data_r, m_addr_r, m_wdata_r, m_be_r, m_valid_r, m_write_r, m_quad_r,
                    r_data_r, ready_r, fail_r, c_ready_r, r_valid_r, fc_send_r, 36'd0};
endmodule
