// SPDX-License-Identifier: MIT
// Fixture adapter matching fit1232's inferred512x2 synchronous OLD_DATA RAM.
module native_m10k_rf(input wire i_clk,input wire[8:0]i_waddr,i_raddr,
    input wire[1:0]i_wdata,input wire i_wen,i_ren,output wire[1:0]o_rdata);
    wire[1:0]physical_q;
    reg regzero,ren;
    always @(posedge i_clk)begin regzero<=!(|i_raddr[8:4]);ren<=i_ren;end
    assign o_rdata=(ren?physical_q:2'bxx)&~{2{regzero}};
    altsyncram #(.operation_mode("DUAL_PORT"),.width_a(2),.widthad_a(9),.numwords_a(512),
        .width_b(2),.widthad_b(9),.numwords_b(512),.address_reg_b("CLOCK0"),
        .outdata_reg_b("UNREGISTERED"),.read_during_write_mode_mixed_ports("OLD_DATA"),
        .ram_block_type("M10K"),.power_up_uninitialized("TRUE"),.intended_device_family("Cyclone V"),
        .clock_enable_input_a("BYPASS"),.clock_enable_input_b("BYPASS"),.clock_enable_output_b("BYPASS")) physical(
        .clock0(i_clk),.clock1(1'b0),.address_a(i_waddr),.data_a(i_wdata),.wren_a(i_wen),
        .address_b(i_raddr),.data_b(2'b0),.wren_b(1'b0),.q_b(physical_q),
        .rden_a(1'b1),.rden_b(1'b1),.byteena_a(1'b1),.byteena_b(1'b1),
        .aclr0(1'b0),.aclr1(1'b0),.addressstall_a(1'b0),.addressstall_b(1'b0),
        .clocken0(1'b1),.clocken1(1'b1),.clocken2(1'b1),.clocken3(1'b1));
endmodule
