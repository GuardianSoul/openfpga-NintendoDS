// RAMs of the integrated DS system (docs/phase2-integration.md).
//
// nds_tdp_ram: true dual-port, 32-bit words, a byte enable per byte on both
// ports, synchronous reads, single clock. A port returns the new data on its
// own write. A read of the address the other port writes in the same cycle
// is undefined (mixed-port DONT_CARE); the simulation model returns inverted
// data then, so a design relying on either answer fails its tests (the
// arm9_ram convention). Quartus does not reliably infer true dual-port M10K
// with byte enables (arm9_ram, nds-fit #50/#51), so synthesis instantiates
// altsyncram directly. INIT names a $readmemh / MIF-compatible hex file for
// ROMs (simulation reads it with $readmemh; Quartus takes init_file).
module nds_tdp_ram #(
    parameter int AW   = 10,
    parameter     INIT = "UNUSED",
    // a read on one port of the word the other port writes: "OLD_DATA"
    // gives the word before the write, "DONT_CARE" an unknown (inverted here)
    parameter     MIXED = "DONT_CARE"
) (
    input  logic          clk,
    input  logic [AW-1:0] a_addr,
    input  logic [3:0]    a_we,
    input  logic [31:0]   a_d,
    output logic [31:0]   a_q,
    input  logic [AW-1:0] b_addr,
    input  logic [3:0]    b_we,
    input  logic [31:0]   b_d,
    output logic [31:0]   b_q
);
`ifdef ALTERA_RESERVED_QIS
    altsyncram #(
        .operation_mode                     ("BIDIR_DUAL_PORT"),
        .ram_block_type                     ("M10K"),
        .intended_device_family             ("Cyclone V"),
        .width_a                            (32),
        .widthad_a                          (AW),
        .numwords_a                         (1 << AW),
        .width_b                            (32),
        .widthad_b                          (AW),
        .numwords_b                         (1 << AW),
        .width_byteena_a                    (4),
        .width_byteena_b                    (4),
        .byte_size                          (8),
        .outdata_reg_a                      ("UNREGISTERED"),
        .outdata_reg_b                      ("UNREGISTERED"),
        .address_reg_b                      ("CLOCK0"),
        .indata_reg_b                       ("CLOCK0"),
        .wrcontrol_wraddress_reg_b          ("CLOCK0"),
        .byteena_reg_b                      ("CLOCK0"),
        .read_during_write_mode_port_a      ("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_port_b      ("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_mixed_ports (MIXED),
        .init_file                          (INIT),
        .power_up_uninitialized             ("FALSE"),
        .lpm_type                           ("altsyncram")
    ) u_ram (
        .clock0    (clk),
        .address_a (a_addr),
        .data_a    (a_d),
        .wren_a    (|a_we),
        .byteena_a (a_we),
        .q_a       (a_q),
        .address_b (b_addr),
        .data_b    (b_d),
        .wren_b    (|b_we),
        .byteena_b (b_we),
        .q_b       (b_q)
    );
`else
    logic [31:0] mem [0:(1<<AW)-1];
    // synthesis translate_off
    initial begin
        for (int i = 0; i < (1<<AW); i++) mem[i] = '0;
        if (INIT != "UNUSED") $readmemh(INIT, mem);
    end
    // synthesis translate_on
    always_ff @(posedge clk) begin
        logic [31:0] w;
        w = mem[a_addr];
        for (int l = 0; l < 4; l++) if (a_we[l]) w[l*8 +: 8] = a_d[l*8 +: 8];
        if (|a_we) mem[a_addr] <= w;
        if (|b_we && b_addr == a_addr && MIXED != "OLD_DATA") a_q <= ~mem[a_addr];
        else a_q <= w;
    end
    always_ff @(posedge clk) begin
        logic [31:0] w;
        w = mem[b_addr];
        for (int l = 0; l < 4; l++) if (b_we[l]) w[l*8 +: 8] = b_d[l*8 +: 8];
        if (|b_we) mem[b_addr] <= w;
        if (|a_we && a_addr == b_addr && MIXED != "OLD_DATA") b_q <= ~mem[b_addr];
        else b_q <= w;
    end
`endif
endmodule

// Simple dual-port, 32-bit words with byte enables on the write port
// (the CPU-side palette and OAM copies). Quartus's byte-enable template.
module nds_sdp_ram #(
    parameter int AW = 9
) (
    input  logic          clk,
    input  logic [3:0]    we,
    input  logic [AW-1:0] waddr,
    input  logic [31:0]   wdata,
    input  logic [AW-1:0] raddr,
    output logic [31:0]   rdata
);
    (* ramstyle = "M10K" *) logic [3:0][7:0] mem [0:(1<<AW)-1];
    always_ff @(posedge clk) begin
        if (we[0]) mem[waddr][0] <= wdata[7:0];
        if (we[1]) mem[waddr][1] <= wdata[15:8];
        if (we[2]) mem[waddr][2] <= wdata[23:16];
        if (we[3]) mem[waddr][3] <= wdata[31:24];
        rdata <= mem[raddr];
    end
endmodule
