// Two-port RAM for the ARM9 memory system (TCMs, cache data and tags).
// Port A: registered-address read/write (WB-stage writes, the fill and
// maintenance state machine, ITCM fetches). Port B: read only, for the
// address the pipeline computes this cycle (E3 data address, F fetch
// address), so that path has no address mux. Synchronous reads on both
// ports; port A returns the new data on its own write. LANE_W bits per
// write enable, one RAM per lane.
//
// Quartus does not infer a true dual-port M10K from this shape: an "old
// data" port A made it duplicate each RAM (one simple dual-port copy per
// read port, nds-fit #50), a "new data" port A made it build the port-A
// copy from registers (#51). So synthesis instantiates altsyncram in
// BIDIR_DUAL_PORT mode directly; the behavioural model is for simulation
// and Yosys.
//
// Byte-lane RAMs of at most 512 words (the cache ways) are one 32-bit
// altsyncram with byte enables instead (PACK): a true dual-port M10K is at
// most 20 bits wide, so a way takes two blocks instead of four
// (phase2-integration.md, "First fit with 3D"). On a partial write, port A
// reads the masked bytes as undefined (Cyclone V true dual-port M10K has no
// NEW_DATA_WITH_NBE_READ, nds-fit #156); the simulation model inverts them,
// so a design that used them fails its tests.
//
// A port-B read of the address port A writes in the same cycle is
// undefined (mixed-port DONT_CARE). The simulation model returns inverted
// data then, so a design that relied on either answer fails its tests.
module arm9_ram #(
  parameter int AW     = 8,       // address bits (depth 2**AW)
  parameter int LANES  = 4,
  parameter int LANE_W = 8,
  // FOLD: the last lane (a narrow counter) lives in the spare byte of lane 0's RAM, which is then one
  // 32-bit altsyncram with byte enables (lane 0's 3 bytes on a_we[0], the counter's byte on
  // a_we[LANES-1]), as the PACK ways are: a block is at most 20 bits wide in true dual port, so a
  // 24-bit lane and a 1-bit lane took 2 + 1 blocks and the folded pair takes 2. Needs LANE_W <= 24
  // and a counter of at most 8 bits. A write of one half leaves the other half's port A read
  // undefined (as a packed write's masked bytes), which the simulation model inverts.
  parameter bit FOLD   = 1'b0
) (
  input  logic                      clk,
  input  logic [AW-1:0]             a_addr,
  input  logic [LANES-1:0]          a_we,
  input  logic [LANES*LANE_W-1:0]   a_d,
  output logic [LANES*LANE_W-1:0]   a_q,
  input  logic [AW-1:0]             b_addr,
  output logic [LANES*LANE_W-1:0]   b_q
);
  localparam bit PACK = LANES == 4 && LANE_W == 8 && AW <= 9;
  localparam int CL = LANES - 1;                    // FOLD: the counter lane
`ifdef ALTERA_RESERVED_QIS
  generate if (PACK) begin : g_pack
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
      .width_byteena_b                    (1),
      .byte_size                          (8),
      .outdata_reg_a                      ("UNREGISTERED"),
      .outdata_reg_b                      ("UNREGISTERED"),
      .address_reg_b                      ("CLOCK0"),
      .indata_reg_b                       ("CLOCK0"),
      .wrcontrol_wraddress_reg_b          ("CLOCK0"),
      .read_during_write_mode_port_a      ("NEW_DATA_NO_NBE_READ"),
      .read_during_write_mode_port_b      ("NEW_DATA_NO_NBE_READ"),
      .read_during_write_mode_mixed_ports ("DONT_CARE"),
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
      .data_b    (32'd0),
      .wren_b    (1'b0),
      .q_b       (b_q)
    );
  end endgenerate
`endif
`ifdef ALTERA_RESERVED_QIS
  generate if (FOLD) begin : g_fold
    logic [31:0] fq_a, fq_b;
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
      .width_byteena_b                    (1),
      .byte_size                          (8),
      .outdata_reg_a                      ("UNREGISTERED"),
      .outdata_reg_b                      ("UNREGISTERED"),
      .address_reg_b                      ("CLOCK0"),
      .indata_reg_b                       ("CLOCK0"),
      .wrcontrol_wraddress_reg_b          ("CLOCK0"),
      .read_during_write_mode_port_a      ("NEW_DATA_NO_NBE_READ"),
      .read_during_write_mode_port_b      ("NEW_DATA_NO_NBE_READ"),
      .read_during_write_mode_mixed_ports ("DONT_CARE"),
      .power_up_uninitialized             ("FALSE"),
      .lpm_type                           ("altsyncram")
    ) u_ram (
      .clock0    (clk),
      .address_a (a_addr),
      .data_a    ({a_d[CL*LANE_W +: 8], {(24-LANE_W){1'b0}}, a_d[0 +: LANE_W]}),
      .wren_a    (a_we[0] | a_we[CL]),
      .byteena_a ({a_we[CL], a_we[0], a_we[0], a_we[0]}),
      .q_a       (fq_a),
      .address_b (b_addr),
      .data_b    (32'd0),
      .wren_b    (1'b0),
      .q_b       (fq_b)
    );
    assign a_q[0 +: LANE_W]          = fq_a[LANE_W-1:0];
    assign b_q[0 +: LANE_W]          = fq_b[LANE_W-1:0];
    assign a_q[CL*LANE_W +: LANE_W]  = {{(LANE_W-8){1'b0}}, fq_a[31:24]};
    assign b_q[CL*LANE_W +: LANE_W]  = {{(LANE_W-8){1'b0}}, fq_b[31:24]};
  end endgenerate
`endif
  // (declared genvar and explicit generate: Quartus Standard rejects inline genvars)
  genvar l;
  generate for (l = 0; l < LANES; l = l + 1) begin : lane
`ifdef ALTERA_RESERVED_QIS
    if (!PACK && !(FOLD && (l == 0 || l == CL))) begin : one
    altsyncram #(
      .operation_mode                     ("BIDIR_DUAL_PORT"),
      .ram_block_type                     ("M10K"),
      .intended_device_family             ("Cyclone V"),
      .width_a                            (LANE_W),
      .widthad_a                          (AW),
      .numwords_a                         (1 << AW),
      .width_b                            (LANE_W),
      .widthad_b                          (AW),
      .numwords_b                         (1 << AW),
      .width_byteena_a                    (1),
      .width_byteena_b                    (1),
      .outdata_reg_a                      ("UNREGISTERED"),
      .outdata_reg_b                      ("UNREGISTERED"),
      .address_reg_b                      ("CLOCK0"),
      .indata_reg_b                       ("CLOCK0"),
      .wrcontrol_wraddress_reg_b          ("CLOCK0"),
      .read_during_write_mode_port_a      ("NEW_DATA_NO_NBE_READ"),
      .read_during_write_mode_port_b      ("NEW_DATA_NO_NBE_READ"),
      .read_during_write_mode_mixed_ports ("DONT_CARE"),
      .power_up_uninitialized             ("FALSE"),
      .lpm_type                           ("altsyncram")
    ) u_ram (
      .clock0    (clk),
      .address_a (a_addr),
      .data_a    (a_d[l*LANE_W +: LANE_W]),
      .wren_a    (a_we[l]),
      .q_a       (a_q[l*LANE_W +: LANE_W]),
      .address_b (b_addr),
      .data_b    ({LANE_W{1'b0}}),
      .wren_b    (1'b0),
      .q_b       (b_q[l*LANE_W +: LANE_W])
    );
    end
`else
    logic [LANE_W-1:0] mem [0:(1<<AW)-1];
    // simulation only: the M10K blocks power up as zero anyway, and Quartus
    // limits loops to 5000 iterations
    // synthesis translate_off
    initial for (int i = 0; i < (1<<AW); i++) mem[i] = '0;
    // synthesis translate_on
    always_ff @(posedge clk) begin
      if (a_we[l]) begin
        mem[a_addr] <= a_d[l*LANE_W +: LANE_W];
        a_q[l*LANE_W +: LANE_W] <= a_d[l*LANE_W +: LANE_W];
      end else if ((PACK && |a_we) || (FOLD && l == 0 && a_we[CL]) || (FOLD && l == CL && a_we[0])) begin
        a_q[l*LANE_W +: LANE_W] <= ~mem[a_addr];     // masked byte of a packed write: undefined
      end else begin
        a_q[l*LANE_W +: LANE_W] <= mem[a_addr];
      end
    end
    always_ff @(posedge clk)
      if ((a_we[l] || (FOLD && (l == 0 || l == CL) && (a_we[0] || a_we[CL]))) && a_addr == b_addr) b_q[l*LANE_W +: LANE_W] <= ~mem[b_addr];
      else                             b_q[l*LANE_W +: LANE_W] <= mem[b_addr];
`endif
  end endgenerate
endmodule
