// SPDX-License-Identifier: MIT
// The APF command area as a mailbox RAM (core_top_ds SHELL_CPU = 2): one
// dual-clock RAM, 256 words, in place of core_bridge_cmd_lean's registers and
// its data table. The bridge (clk_74a) reads and writes it; SERV
// (nds_cart_scpu, clk_bus side) runs the host and target command protocols
// on the other port in firmware (sw/scpu/boot.c).
//
// Words (bridge addresses as core_bridge_cmd_lean's):
//   0-63     the data table, 0xF8002000 + 4w (the APF's slot IDs and sizes)
//   64-95    the host command area, 0xF8000000 + 4w (command/status at 0)
//   96-127   the target command area, 0xF8001000 + 4w
//   120-124  (in the target area, past the APF's words) the fetch's slots: a
//            write to FETCH_WIN + o goes to ROM-cache slot word[120 + o/4096]
//   128-255  SERV's boot code and data (sw/scpu/boot.c; not reachable from
//            the bridge), loaded at configuration from MBOX_INIT
//
// The bridge's read data comes two clocks after its address (the RAM's
// registered output), as the data table's did; a read of the word last
// written, within the five clocks before the write shows there, gets the
// written value (the host writes a command and reads its status at once). A bridge write of a command
// (0x434D....) to word 64 and any bridge write to word 96 toggle h_ev / t_ev
// for SERV's wait register.
//
// Fetch window writes: the slot word is read at the write's address, so the
// write leaves here four clocks late, with its slot (fw_* outputs).
//
// The RAM: an altsyncram (bidirectional dual port, a clock a port, outputs
// registered, MBOX_MIF) for Quartus; the same timing in logic for simulation.
`default_nettype none
module nds_mbox #(
    parameter MBOX_INIT = "",                  // simulation: $readmemh of sw/scpu/mbox.hex
    parameter MBOX_MIF = "mbox.mif",            // Quartus: the same words as a MIF (scripts/build_ds.sh)
    parameter [31:0] FETCH_WIN = 32'h2000_0000
) (
    input wire clk_74a,
    input wire bridge_endian_little,
    input wire [31:0] bridge_addr,
    input wire bridge_rd, bridge_wr,
    input wire [31:0] bridge_wr_data,
    output reg [31:0] bridge_rd_data = 0,       // for bridge addresses 0xF8xxxxxx
    output reg h_ev = 0, t_ev = 0,              // toggles: a host command, a target status write
    // fetch window writes with their slot (three clocks after the bridge write)
    output reg fw_v = 0,
    output reg [13:0] fw_slot = 0,
    output reg [9:0] fw_word = 0,
    output reg [31:0] fw_data = 0,
    // SERV's port (clk_bus)
    input wire clk,
    input wire [7:0] s_addr,
    input wire s_we,
    input wire [31:0] s_wdata,
    output wire [31:0] s_q                      // two clocks after s_addr
);
    // endianness (core_bridge_cmd_lean's): bridge words byte-swapped when little
    (* async_reg = "true" *) reg el1 = 0, el2 = 0, el = 0;
    always @(posedge clk_74a) begin el1 <= bridge_endian_little; el2 <= el1; el <= el2; end
    function automatic [31:0] sw(input [31:0] x);
        sw = el ? {x[7:0], x[15:8], x[23:16], x[31:24]} : x;
    endfunction

    // bridge port
    wire [7:0] b_map = bridge_addr[13:12] == 2'd2 ? {2'b00, bridge_addr[7:2]} :
                       bridge_addr[12] ? {3'b011, bridge_addr[6:2]} : {3'b010, bridge_addr[6:2]};
    wire in_cmd = bridge_addr[31:24] == 8'hF8;
    wire in_fetch = bridge_addr[31:16] == FETCH_WIN[31:16];
    reg [7:0] b_addr = 0;
    reg b_we = 0;
    reg [31:0] b_d = 0;
    wire [31:0] b_q2;                       // the RAM's registered output: two clocks after b_addr
    reg f0 = 0, f1 = 0, f2 = 0;
    reg [7:0] wf_a = 0;
    reg [31:0] wf_d = 0;
    reg [2:0] wf_n = 7;
    reg [9:0] fw0 = 0, fw1 = 0, fw2 = 0;
    reg [31:0] fd0 = 0, fd1 = 0, fd2 = 0;
    always @(posedge clk_74a) begin
        b_addr <= in_fetch && bridge_wr ? {5'b01111, bridge_addr[14:12]} : b_map;
        b_we <= bridge_wr && in_cmd;
        b_d <= sw(bridge_wr_data);
        if (bridge_rd && in_cmd) bridge_rd_data <= wf_n < 3'd5 && b_map == wf_a ? wf_d : sw(b_q2);
        if (bridge_wr && in_cmd) begin wf_a <= b_map; wf_d <= bridge_wr_data; wf_n <= 0; end
        else if (wf_n != 3'd7) wf_n <= wf_n + 1'b1;
        if (bridge_wr && in_cmd && b_map == 8'd64 && sw(bridge_wr_data) >> 16 == 32'h434D) h_ev <= !h_ev;
        if (bridge_wr && in_cmd && b_map == 8'd96) t_ev <= !t_ev;
        // the fetch window: the slot word arrives with b_q (two clocks), the write a clock after
        f0 <= bridge_wr && in_fetch; fw0 <= bridge_addr[11:2]; fd0 <= bridge_wr_data;
        f1 <= f0; fw1 <= fw0; fd1 <= fd0;
        f2 <= f1; fw2 <= fw1; fd2 <= fd1;
        fw_v <= f2; fw_word <= fw2; fw_data <= fd2; fw_slot <= b_q2[13:0];
    end

    // synthesis translate_off
    `ifdef MBOX_TRACE
    always @(posedge clk_74a) begin
        if (bridge_wr && in_cmd) $display("[%0t] MB bridge W %0d %h", $time, b_map, sw(bridge_wr_data));
        if (bridge_rd && in_cmd) $display("[%0t] MB bridge R %0d %h", $time, b_map, wf_n < 3'd5 && b_map == wf_a ? wf_d : sw(b_q2));
    end
    always @(posedge clk) if (s_we) $display("[%0t] MB serv W %0d %h", $time, s_addr, s_wdata);
    `endif
    // synthesis translate_on
    // the RAM: port A SERV's (clk), port B the bridge's (clk_74a); both outputs registered
`ifdef ALTERA_RESERVED_QIS
    altsyncram #(.operation_mode("BIDIR_DUAL_PORT"), .width_a(32), .widthad_a(8), .numwords_a(256),
        .width_b(32), .widthad_b(8), .numwords_b(256), .outdata_reg_a("CLOCK0"), .outdata_reg_b("CLOCK1"),
        .address_reg_b("CLOCK1"), .indata_reg_b("CLOCK1"), .wrcontrol_wraddress_reg_b("CLOCK1"),
        .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"), .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
        .width_byteena_a(1), .width_byteena_b(1), .init_file(MBOX_MIF), .intended_device_family("Cyclone V"),
        .lpm_type("altsyncram"), .power_up_uninitialized("FALSE"), .ram_block_type("M10K"),
        .outdata_aclr_a("NONE"), .outdata_aclr_b("NONE"), .clock_enable_input_a("BYPASS"), .clock_enable_input_b("BYPASS"),
        .clock_enable_output_a("BYPASS"), .clock_enable_output_b("BYPASS")) ram (
        .clock0(clk), .address_a(s_addr), .data_a(s_wdata), .wren_a(s_we), .q_a(s_q),
        .clock1(clk_74a), .address_b(b_addr), .data_b(b_d), .wren_b(b_we), .q_b(b_q2),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0), .byteena_a(1'b1), .byteena_b(1'b1),
        .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(1'b1), .rden_b(1'b1));
`else
    reg [31:0] mem [0:255];
    initial if (MBOX_INIT != "") $readmemh(MBOX_INIT, mem);
    reg [31:0] s_q1 = 0, s_qr = 0, b_q = 0, b_qr = 0;
    always @(posedge clk) begin
        if (s_we) mem[s_addr] <= s_wdata;
        s_q1 <= mem[s_addr];
        s_qr <= s_q1;
    end
    always @(posedge clk_74a) begin
        if (b_we) mem[b_addr] <= b_d;
        b_q <= mem[b_addr];
        b_qr <= b_q;
    end
    assign s_q = s_qr, b_q2 = b_qr;
`endif
endmodule
`default_nettype wire
