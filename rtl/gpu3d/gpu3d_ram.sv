// Simple dual-port RAM: one write port, one registered read port
// (old data on a same-address read/write). Maps to M10K/MLAB; STYLE is
// Quartus's ramstyle ("AUTO" lets it choose; "MLAB" for small tables, to
// save M10K blocks).
module gpu3d_ram #(
    parameter int W  = 8,
    parameter int AW = 8,
    parameter     STYLE = "AUTO"
) (
    input  logic          clk,
    input  logic          we,
    input  logic [AW-1:0] waddr,
    input  logic [W-1:0]  wdata,
    input  logic [AW-1:0] raddr,
    output logic [W-1:0]  rdata
);
    (* ramstyle = STYLE *) logic [W-1:0] mem [0:(1<<AW)-1];
    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
`ifndef SYNTHESIS
        // synthesis translate_off
        // An MLAB need not return old data on a same-address read and
        // write: the simulation returns garbage then, so a design that
        // depended on it would fail the pixel-exact checks
        if ((STYLE == "MLAB" || STYLE == "M10K, no_rw_check") && we && waddr == raddr) rdata <= ~mem[raddr];
        // synthesis translate_on
`endif
    end
endmodule

// gpu3d_ram with a read enable: rdata keeps its value while re is low (the
// M10K's read clock enable)
module gpu3d_ram_re #(
    parameter int W  = 8,
    parameter int AW = 8
) (
    input  logic          clk,
    input  logic          we,
    input  logic [AW-1:0] waddr,
    input  logic [W-1:0]  wdata,
    input  logic          re,
    input  logic [AW-1:0] raddr,
    output logic [W-1:0]  rdata
);
    logic [W-1:0] mem [0:(1<<AW)-1];
    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        if (re) rdata <= mem[raddr];
    end
endmodule

// Small table with a combinational read (a register file in MLAB): one
// write port, the read sees the entry as written by the last clock edge.
// FE = 1: in M10K instead, the read address taken on the falling edge (the Saturn core's FERAM): the word is out
// in the clock's second half, as the MLAB's asynchronous read gives it (the write at this clock's rising edge
// seen). raddr must settle in the first half and rdata be used within the second (gxeng's u_vm: from registers,
// into registers)
module gpu3d_lram #(
    parameter int W  = 8,
    parameter int AW = 2,
    parameter bit FE = 1'b0
) (
    input  logic          clk,
    input  logic          we,
    input  logic [AW-1:0] waddr,
    input  logic [W-1:0]  wdata,
    input  logic [AW-1:0] raddr,
    output logic [W-1:0]  rdata
);
    generate if (FE) begin : g_fe
        (* ramstyle = "M10K, no_rw_check" *) logic [W-1:0] mem [0:(1<<AW)-1];
        always_ff @(posedge clk) if (we) mem[waddr] <= wdata;
        always_ff @(negedge clk) rdata <= mem[raddr];
    end else begin : g_ml
        (* ramstyle = "MLAB, no_rw_check" *) logic [W-1:0] mem [0:(1<<AW)-1];
        always_ff @(posedge clk) if (we) mem[waddr] <= wdata;
        assign rdata = mem[raddr];
    end endgenerate
endmodule

// True dual-port RAM with one write port: port A writes or reads (a write returns the new word on
// a_q), port B only reads; a port-B read of the word port A writes in the same clock returns the
// old word (as gpu3d_ram). One M10K set for two readers of the same table, where two gpu3d_ram copies
// written together would take two. Synthesis instantiates altsyncram (true dual-port inference is
// unreliable: nds_tdp_ram).
module gpu3d_tdp #(
    parameter int W  = 8,
    parameter int AW = 8
) (
    input  logic          clk,
    input  logic [AW-1:0] a_addr,
    input  logic          a_we,
    input  logic [W-1:0]  a_d,
    output logic [W-1:0]  a_q,
    input  logic [AW-1:0] b_addr,
    output logic [W-1:0]  b_q
);
`ifdef ALTERA_RESERVED_QIS
    altsyncram #(
        .operation_mode                     ("BIDIR_DUAL_PORT"),
        .ram_block_type                     ("M10K"),
        .intended_device_family             ("Cyclone V"),
        .width_a                            (W),
        .widthad_a                          (AW),
        .numwords_a                         (1 << AW),
        .width_b                            (W),
        .widthad_b                          (AW),
        .numwords_b                         (1 << AW),
        .outdata_reg_a                      ("UNREGISTERED"),
        .outdata_reg_b                      ("UNREGISTERED"),
        .address_reg_b                      ("CLOCK0"),
        .indata_reg_b                       ("CLOCK0"),
        .wrcontrol_wraddress_reg_b          ("CLOCK0"),
        .read_during_write_mode_port_a      ("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_port_b      ("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_mixed_ports ("OLD_DATA"),
        .power_up_uninitialized             ("FALSE"),
        .lpm_type                           ("altsyncram")
    ) u_ram (
        .clock0    (clk),
        .address_a (a_addr),
        .data_a    (a_d),
        .wren_a    (a_we),
        .q_a       (a_q),
        .address_b (b_addr),
        .data_b    ({W{1'b0}}),
        .wren_b    (1'b0),
        .q_b       (b_q)
    );
`else
    logic [W-1:0] mem [0:(1<<AW)-1];
    always_ff @(posedge clk) begin
        if (a_we) begin mem[a_addr] <= a_d; a_q <= a_d; end
        else a_q <= mem[a_addr];
        b_q <= mem[b_addr];
    end
`endif
endmodule

// A span-constant word (gpu3d_raster's descriptor fields abase/aqs), written
// when the walker loads a span. Once an M10K word read every clock, but
// Quartus built its two words as flops (nds-fit #867: 0 M10K, 198 registers
// and 50 ALMs, mem and q): now the word itself, q taken at the write. q
// changes a clock earlier than the RAM's, still while P0-P13 are empty (the
// raster's g_dram check), and build_ds.sh's sd_cur -> P12 multicycle and the
// sd_nx hold exception still name it (gpu3d_dword:g_dram.u_dram|q).
module gpu3d_dword #(
    parameter int W = 160
) (
    input  logic         clk,
    input  logic         we,
    input  logic [W-1:0] wd,
    output logic [W-1:0] q
);
    always_ff @(posedge clk)
        if (we) q <= wd;
endmodule
// A delay line's ring with its stage register folded into the read: rdata is
// the register `if (en) r <= mem[raddr]` an MLAB ring (gpu3d_lram) feeds, so
// it fits an M10K (address register with a clock enable; old data on a
// same-address read and write, as the MLAB's read before the edge gave).
module gpu3d_sram_en #(
    parameter int W  = 8,
    parameter int AW = 5
) (
    input  logic          clk,
    input  logic          we,
    input  logic [AW-1:0] waddr,
    input  logic [W-1:0]  wdata,
    input  logic          en,
    input  logic [AW-1:0] raddr,
    output logic [W-1:0]  rdata
);
    (* ramstyle = "M10K" *) logic [W-1:0] mem [0:(1<<AW)-1];
    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        if (en) rdata <= mem[raddr];
    end
endmodule
// A delay ring (gpu3d_raster's dly_wp lines) in M10K: rdata is what an MLAB
// ring (gpu3d_lram written at wp on every advance, read combinationally at
// wp - D) shows, from a registered read. The ring's contents and wp change
// only on an advance (en: the clocks wp moves on), so the entry the ring
// shows after an advance can be read on it: wp - D + 1 into the M10K's read
// register (K = 1), or wp - D + 2 one advance earlier into it and then into
// one more register (K = 2: an output that feeds logic starts from a
// register; Quartus can take it as the block's output register).
// The read never meets the write (D > K) and the entry is not yet
// overwritten (D - K < 2^AW). D <= K keeps the MLAB ring.
module gpu3d_dring #(
    parameter int W  = 8,
    parameter int AW = 5,
    parameter int D  = 2,
    parameter int K  = 1
) (
    input  logic          clk,
    input  logic          we,             // write wdata at wp (the ring's write enable)
    input  logic          en,             // wp moves on this clock
    input  logic [AW-1:0] wp,
    input  logic [W-1:0]  wdata,
    output logic [W-1:0]  rdata
);
    generate
    if (D > K && D - K < (1 << AW)) begin : g_m10k
        logic [W-1:0] q;
        gpu3d_sram_en #(.W(W), .AW(AW)) u_r (
            .clk, .we, .waddr(wp), .wdata, .en, .raddr(AW'(wp - AW'(D - K))), .rdata(q));
        if (K == 2) begin : g_k2
            always_ff @(posedge clk) if (en) rdata <= q;
        end else begin : g_k1
            assign rdata = q;
        end
`ifndef SYNTHESIS
        initial if (K != 1 && K != 2) $error("gpu3d_dring: K is 1 or 2");
`endif
    end else begin : g_mlab
        gpu3d_lram #(.W(W), .AW(AW)) u_r (
            .clk, .we, .waddr(wp), .wdata, .raddr(AW'(wp - AW'(D))), .rdata);
    end
    endgenerate
endmodule
// Two delay rings (gpu3d_dring) on the same wp / we / en in one M10K word
// (W0 + W1 <= 40): both read at wp - C into the block's read register, then
// ring i passes K_i - 1 = D_i - C - 1 more registers (one an advance), so
// each shows what its own gpu3d_dring would (the entry written D_i advances
// ago). C >= 1 keeps the read off the write; D_i - C < 2^AW keeps the entry.
module gpu3d_dring2 #(
    parameter int W0 = 8,
    parameter int D0 = 2,
    parameter int W1 = 8,
    parameter int D1 = 2,
    parameter int C  = 1,
    parameter int AW = 5
) (
    input  logic           clk,
    input  logic           we,
    input  logic           en,
    input  logic [AW-1:0]  wp,
    input  logic [W0-1:0]  wdata0,
    input  logic [W1-1:0]  wdata1,
    output logic [W0-1:0]  rdata0,
    output logic [W1-1:0]  rdata1
);
    localparam int K0 = D0 - C, K1 = D1 - C;
    logic [W0+W1-1:0] q;
    gpu3d_sram_en #(.W(W0 + W1), .AW(AW)) u_r (
        .clk, .we, .waddr(wp), .wdata({wdata1, wdata0}), .en, .raddr(AW'(wp - AW'(C))), .rdata(q));
    generate
        if (K0 == 1) begin : g_k0
            assign rdata0 = q[W0-1:0];
        end else begin : g_s0
            logic [K0-2:0][W0-1:0] s;
            always_ff @(posedge clk) if (en) begin
                s[0] <= q[W0-1:0];
                for (int i = 1; i < K0 - 1; i++) s[i] <= s[i-1];
            end
            assign rdata0 = s[K0-2];
        end
        if (K1 == 1) begin : g_k1
            assign rdata1 = q[W0+W1-1:W0];
        end else begin : g_s1
            logic [K1-2:0][W1-1:0] s;
            always_ff @(posedge clk) if (en) begin
                s[0] <= q[W0+W1-1:W0];
                for (int i = 1; i < K1 - 1; i++) s[i] <= s[i-1];
            end
            assign rdata1 = s[K1-2];
        end
    endgenerate
`ifndef SYNTHESIS
    initial if (C < 1 || K0 < 1 || K1 < 1 || D0 - C >= (1 << AW) || D1 - C >= (1 << AW) || W0 + W1 > 40)
        $error("gpu3d_dring2: C %0d, D %0d/%0d, W %0d+%0d out of range", C, D0, D1, W0, W1);
`endif
endmodule

// Two W-bit tables (W <= 20) written at one address by separate enables and
// read together at one address, in one M10K: halves of a 40-bit word with
// byte enables (10-bit bytes). Registered read (raddr a clock before rdata);
// K = 2 adds the block's output register (raddr two clocks before rdata). A
// same-address read and write returns undefined data (mixed-port DONT_CARE):
// the simulation inverts the word then, so a design that relied on it fails
// its checks. Synthesis instantiates altsyncram (byte enables are not
// inferred for 10-bit bytes).
module gpu3d_ram_be2 #(
    parameter int W  = 17,
    parameter int AW = 5,
    parameter int K  = 1
) (
    input  logic          clk,
    input  logic          we0,            // write wdata into table 0 at waddr
    input  logic          we1,            // ... table 1
    input  logic [AW-1:0] waddr,
    input  logic [W-1:0]  wdata,
    input  logic [AW-1:0] raddr,
    output logic [W-1:0]  rdata0,
    output logic [W-1:0]  rdata1
);
    logic [39:0] q;
    assign rdata0 = q[W-1:0];
    assign rdata1 = q[20 +: W];
`ifdef ALTERA_RESERVED_QIS
    altsyncram #(
        .operation_mode                     ("DUAL_PORT"),
        .ram_block_type                     ("M10K"),
        .intended_device_family             ("Cyclone V"),
        .width_a                            (40),
        .widthad_a                          (AW),
        .numwords_a                         (1 << AW),
        .width_b                            (40),
        .widthad_b                          (AW),
        .numwords_b                         (1 << AW),
        .width_byteena_a                    (4),
        .byte_size                          (10),
        .outdata_reg_b                      (K == 2 ? "CLOCK0" : "UNREGISTERED"),
        .address_reg_b                      ("CLOCK0"),
        .rdcontrol_reg_b                    ("CLOCK0"),
        .address_aclr_b                     ("NONE"),
        .outdata_aclr_b                     ("NONE"),
        .read_during_write_mode_mixed_ports ("DONT_CARE"),
        .power_up_uninitialized             ("FALSE"),
        .lpm_type                           ("altsyncram")
    ) u_ram (
        .clock0    (clk),
        .wren_a    (we0 || we1),
        .address_a (waddr),
        .data_a    ({{(20-W){1'b0}}, wdata, {(20-W){1'b0}}, wdata}),
        .byteena_a ({we1, we1, we0, we0}),
        .address_b (raddr),
        .q_b       (q)
    );
`else
    logic [W-1:0] m0 [0:(1<<AW)-1];
    logic [W-1:0] m1 [0:(1<<AW)-1];
    logic [39:0]  r;
    always_ff @(posedge clk) begin
        if (we0) m0[waddr] <= wdata;
        if (we1) m1[waddr] <= wdata;
        r <= {{(20-W){1'b0}}, m1[raddr], {(20-W){1'b0}}, m0[raddr]};
`ifndef SYNTHESIS
        // synthesis translate_off
        if ((we0 || we1) && waddr == raddr) r <= ~{{(20-W){1'b0}}, m1[raddr], {(20-W){1'b0}}, m0[raddr]};
        // synthesis translate_on
`endif
    end
    generate if (K == 2) begin : g_k2
        always_ff @(posedge clk) q <= r;
    end else begin : g_k1
        assign q = r;
    end endgenerate
`ifndef SYNTHESIS
    initial if (W > 20 || (K != 1 && K != 2)) $error("gpu3d_ram_be2: W <= 20, K 1 or 2");
`endif
`endif
endmodule
// Four W-bit tables (W <= 10) written at one address by separate enables and
// read together at one address, in one M10K: quarters of a 40-bit word with
// byte enables (10-bit bytes; nds_lcache_n's four ways). Registered read; a
// same-address read and write returns the old word (mixed-port OLD_DATA), as
// the inferred RAM it replaces. Power-up 0. Synthesis instantiates altsyncram
// (byte enables are not inferred for 10-bit bytes).
module gpu3d_ram_be4 #(
    parameter int W  = 10,
    parameter int AW = 7
) (
    input  logic               clk,
    input  logic [3:0]         we,            // table k written at waddr
    input  logic [AW-1:0]      waddr,
    input  logic [3:0][W-1:0]  wdata,
    input  logic [AW-1:0]      raddr,
    output logic [3:0][W-1:0]  rdata
);
    logic [39:0] q;
    always_comb
        for (int k = 0; k < 4; k++) rdata[k] = q[10*k +: W];
`ifdef ALTERA_RESERVED_QIS
    logic [39:0] d;
    always_comb begin
        d = '0;
        for (int k = 0; k < 4; k++) d[10*k +: W] = wdata[k];
    end
    altsyncram #(
        .operation_mode                     ("DUAL_PORT"),
        .ram_block_type                     ("M10K"),
        .intended_device_family             ("Cyclone V"),
        .width_a                            (40),
        .widthad_a                          (AW),
        .numwords_a                         (1 << AW),
        .width_b                            (40),
        .widthad_b                          (AW),
        .numwords_b                         (1 << AW),
        .width_byteena_a                    (4),
        .byte_size                          (10),
        .outdata_reg_b                      ("UNREGISTERED"),
        .address_reg_b                      ("CLOCK0"),
        .rdcontrol_reg_b                    ("CLOCK0"),
        .address_aclr_b                     ("NONE"),
        .outdata_aclr_b                     ("NONE"),
        .read_during_write_mode_mixed_ports ("OLD_DATA"),
        .power_up_uninitialized             ("FALSE"),
        .lpm_type                           ("altsyncram")
    ) u_ram (
        .clock0    (clk),
        .wren_a    (|we),
        .address_a (waddr),
        .data_a    (d),
        .byteena_a (we),
        .address_b (raddr),
        .q_b       (q)
    );
`else
    logic [W-1:0] m [4][0:(1<<AW)-1];
    initial for (int k = 0; k < 4; k++) for (int i = 0; i < (1 << AW); i++) m[k][i] = '0;
    always_ff @(posedge clk) begin
        for (int k = 0; k < 4; k++) if (we[k]) m[k][waddr] <= wdata[k];
        q <= '0;
        for (int k = 0; k < 4; k++) q[10*k +: W] <= m[k][raddr];
    end
`ifndef SYNTHESIS
    initial if (W > 10) $error("gpu3d_ram_be4: W <= 10");
`endif
`endif
endmodule

// True dual-port RAM on two clocks (a double-pumped block, docs/phase2-integration.md
// "Double-pumped RAMs"): port A only reads, on clk_a; port B reads or writes, on clk_b
// (2 x clk_a, phase 0, in its users). Registered reads, unregistered outputs; power-up 0.
// Mixed-port read-during-write is undefined across two clocks (DONT_CARE): the users
// never write on B at an edge where A reads, which the simulation checks. Synthesis
// instantiates altsyncram (true dual-port inference is unreliable: gpu3d_tdp).
module gpu3d_tdp2c #(
    parameter int W  = 8,
    parameter int AW = 8
) (
    input  logic          clk_a,
    input  logic [AW-1:0] a_addr,
    output logic [W-1:0]  a_q,
    input  logic          clk_b,
    input  logic [AW-1:0] b_addr,
    input  logic          b_we,
    input  logic [W-1:0]  b_d,
    output logic [W-1:0]  b_q
);
`ifdef ALTERA_RESERVED_QIS
    altsyncram #(
        .operation_mode                     ("BIDIR_DUAL_PORT"),
        .ram_block_type                     ("M10K"),
        .intended_device_family             ("Cyclone V"),
        .width_a                            (W),
        .widthad_a                          (AW),
        .numwords_a                         (1 << AW),
        .width_b                            (W),
        .widthad_b                          (AW),
        .numwords_b                         (1 << AW),
        .outdata_reg_a                      ("UNREGISTERED"),
        .outdata_reg_b                      ("UNREGISTERED"),
        .address_reg_b                      ("CLOCK1"),
        .indata_reg_b                       ("CLOCK1"),
        .wrcontrol_wraddress_reg_b          ("CLOCK1"),
        .read_during_write_mode_port_a      ("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_port_b      ("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_mixed_ports ("DONT_CARE"),
        .power_up_uninitialized             ("FALSE"),
        .lpm_type                           ("altsyncram")
    ) u_ram (
        .clock0    (clk_a),
        .clock1    (clk_b),
        .address_a (a_addr),
        .data_a    ({W{1'b0}}),
        .wren_a    (1'b0),
        .q_a       (a_q),
        .address_b (b_addr),
        .data_b    (b_d),
        .wren_b    (b_we),
        .q_b       (b_q)
    );
`else
    logic [W-1:0] mem [0:(1<<AW)-1];
    initial for (int i = 0; i < (1 << AW); i++) mem[i] = '0;
    always_ff @(posedge clk_a) a_q <= mem[a_addr];
    always_ff @(posedge clk_b) begin
        if (b_we) begin mem[b_addr] <= b_d; b_q <= b_d; end
        else b_q <= mem[b_addr];
    end
`ifndef SYNTHESIS
    // synthesis translate_off
    // a B write at an A read's edge: undefined in the block
    realtime wt = -1.0;
    always @(posedge clk_b) if (b_we) wt = $realtime;
    always @(posedge clk_a) #0 if (wt == $realtime) $error("gpu3d_tdp2c: a port-B write at a port-A read's edge");
    // synthesis translate_on
`endif
`endif
endmodule
