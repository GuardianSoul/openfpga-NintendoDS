// Full64KiB private and32KiB shared WRAM. Private words are packed five
// per four rows on aligned clk2; logical access/ACK timing is unchanged.
// Both clients use physical SRAM-map addresses, after WRAMCNT translation.
// Port A is the CPU's fetch/data arbiter; port B is the fabric/loader.
// A conflicting fabric access wins; the CPU retries rather than observing
// mixed-port read-during-write data. Read/read collisions run concurrently.
module arm7_wram #(
  // Prototype only: Root enables this in a qualified combined source.
  parameter bit SHARED_DENSE = 1'b0
) (
  input logic clk, clk2, rst,
  input logic a_req, a_we,
  input logic [17:2] a_addr,
  input logic [3:0] a_be,
  input logic [31:0] a_wdata,
  output logic a_ok,
  output logic [31:0] a_rdata,
  input logic b_req, b_we,
  input logic [17:2] b_addr,
  input logic [3:0] b_be,
  input logic [31:0] b_wdata,
  output logic b_done,
  output logic [31:0] b_rdata
);
  logic aq_bank, bq_bank;
  logic [31:0] a7q, asq, b7q, bsq;
  wire b_take = b_req && !b_done && !rst;
  wire collision = b_take && a_req && a_addr == b_addr && (a_we || b_we);
  wire a_take = a_req && !collision && !rst;
  always_ff @(posedge clk) begin
    a_ok <= a_take;
    b_done <= b_take;
    aq_bank <= a_addr[16]; bq_bank <= b_addr[16];
  end
  arm7_wram_dense u_private (
    .clk, .clk2, .a_addr(a_addr[15:2]), .a_we(a_take && a_we && !a_addr[16] ? a_be : 4'd0),
    .a_d(a_wdata), .a_q(a7q), .b_addr(b_addr[15:2]),
    .b_we(b_take && b_we && !b_addr[16] ? b_be : 4'd0), .b_d(b_wdata), .b_q(b7q));
  arm7_wram_shared #(.DENSE(SHARED_DENSE)) u_shared (
    .clk, .clk2, .a_addr(a_addr[14:2]), .a_we(a_take && a_we && a_addr[16] ? a_be : 4'd0),
    .a_d(a_wdata), .a_q(asq), .b_addr(b_addr[14:2]),
    .b_we(b_take && b_we && b_addr[16] ? b_be : 4'd0), .b_d(b_wdata), .b_q(bsq));
  assign a_rdata = aq_bank ? asq : a7q;
  assign b_rdata = bq_bank ? bsq : b7q;
endmodule

// Four native10-bit banks,13108rows each: 5x32bits in4x40bits. Words0..3
// use10bits in three banks and2bits in their own bank. Word4 uses the spare
// 8bits of row=bank. Each client therefore reads exactly one cell per bank.
// E reads both ports; M (the middle clk2 edge) writes merged whole cells.
// rden=0 at M holds Q until the next E, including on either port's write.
module arm7_wram_dense (
  input logic clk, clk2,
  input logic [13:0] a_addr, b_addr,
  input logic [3:0] a_we, b_we,
  input logic [31:0] a_d, b_d,
  output logic [31:0] a_q, b_q
);
`ifdef ALTERA_RESERVED_QIS
  logic epoch=1'b0, seen=1'b0;
  wire mid=epoch!=seen;
  always_ff @(posedge clk) epoch<=!epoch;
  always_ff @(posedge clk2) seen<=epoch;
  wire [13:0] agroup=a_addr/14'd5, bgroup=b_addr/14'd5;
  wire [2:0] aslot=3'(a_addr%14'd5), bslot=3'(b_addr%14'd5);
  logic [2:0] asq=3'd0, bsq=3'd0;
  logic [31:0] adq=32'd0, bdq=32'd0, amq=32'd0, bmq=32'd0;
  wire [31:0] amask={{8{a_we[3]}},{8{a_we[2]}},{8{a_we[1]}},{8{a_we[0]}}};
  wire [31:0] bmask={{8{b_we[3]}},{8{b_we[2]}},{8{b_we[1]}},{8{b_we[0]}}};
  always_ff @(posedge clk2) if(!mid) begin
    asq<=aslot;bsq<=bslot;adq<=a_d;bdq<=b_d;amq<=amask;bmq<=bmask;
  end
  function automatic [9:0] field(input logic [31:0] data,
                                  input logic [2:0] slot,input integer bank);
    if(slot==3'd4) return {data[bank*8+:8],2'b00};
    if(slot==3'(bank)) return {8'd0,data[bank*10+:2]};
    if(slot<3'(bank)) return 10'(data>>(bank*10-8));
    return 10'(data>>(bank*10));
  endfunction
  function automatic [31:0] expand(input logic [9:0] data,
                                    input logic [2:0] slot,input integer bank);
    if(slot==3'd4) return {24'd0,data[9:2]}<<(bank*8);
    if(slot==3'(bank)) return {30'd0,data[1:0]}<<(bank*10);
    if(slot<3'(bank)) return {22'd0,data}<<(bank*10-8);
    return {22'd0,data}<<(bank*10);
  endfunction
  wire [31:0] aq[0:3],bq[0:3];
  genvar bank;
  generate for(bank=0;bank<4;bank=bank+1)begin:g_bank
    wire [13:0] ar = {agroup[11:0],2'b00} + (aslot == 3'd4 ? 14'(bank) : {11'd0,aslot});
    wire [13:0] br = {bgroup[11:0],2'b00} + (bslot == 3'd4 ? 14'(bank) : {11'd0,bslot});
    logic [13:0] arq=14'd0,brq=14'd0;
    always_ff @(posedge clk2)if(!mid)begin arq<=ar;brq<=br;end
    wire [9:0] qa,qb;
    wire [9:0] a_write_mask=field(amq,asq,bank),b_write_mask=field(bmq,bsq,bank);
    wire [9:0] a_bits=field(adq,asq,bank),b_bits=field(bdq,bsq,bank);
    wire merge_write=arq==brq&&(|a_write_mask)&&(|b_write_mask);
    wire [9:0] merged_mask=a_write_mask | b_write_mask;
    wire [9:0] aword=(qa&~a_write_mask)|(a_bits&a_write_mask);
    wire [9:0] bword=merge_write?
      ((qb&~merged_mask)|(a_bits&a_write_mask&~b_write_mask)|(b_bits&b_write_mask)):
      ((qb&~b_write_mask)|(b_bits&b_write_mask));
    altsyncram #(
      .operation_mode("BIDIR_DUAL_PORT"),.ram_block_type("M10K"),.intended_device_family("Cyclone V"),
      // Auto slicing used20blocks/bank in actual1192. Limit each native
      // slice to1Kx10 so13108rows need13blocks, not deeper narrow slices.
      .maximum_depth(1024),
      .width_a(10),.widthad_a(14),.numwords_a(13108),
      .width_b(10),.widthad_b(14),.numwords_b(13108),
      .outdata_reg_a("UNREGISTERED"),.outdata_reg_b("UNREGISTERED"),
      .address_reg_b("CLOCK0"),.indata_reg_b("CLOCK0"),.wrcontrol_wraddress_reg_b("CLOCK0"),
      .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
      .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
      .read_during_write_mode_mixed_ports("OLD_DATA"),
      .power_up_uninitialized("FALSE"),.lpm_type("altsyncram")
    )u_ram(.clock0(clk2),.address_a(mid?arq:ar),.address_b(mid?brq:br),
      .data_a(aword),.data_b(bword),
      .wren_a(mid&&(|a_write_mask)&&!merge_write),.wren_b(mid&&(|b_write_mask)),
      .rden_a(!mid),.rden_b(!mid),.q_a(qa),.q_b(qb));
    assign aq[bank]=expand(qa,asq,bank);
    assign bq[bank]=expand(qb,bsq,bank);
  end endgenerate
  // The original primitive returns own-port NEW_DATA for byte writes.
  assign a_q=((aq[0]|aq[1]|aq[2]|aq[3])&~amq)|(adq&amq);
  assign b_q=((bq[0]|bq[1]|bq[2]|bq[3])&~bmq)|(bdq&bmq);
`else
  // Same logical/debug image and drained hierarchical importer as before.
  // Actual native packing/RMW/phase/publication is independently exercised
  // using this module's QIS branch and the shipped vendor RAM model.
  logic [31:0] mem[0:16383];
  initial for(integer i=0;i<16384;i=i+1)mem[i]=32'd0;
  always_ff @(posedge clk)begin
    logic[31:0] w;
    w=mem[a_addr];
    for(integer l=0;l<4;l=l+1)if(a_we[l])w[l*8+:8]=a_d[l*8+:8];
    if(|a_we)mem[a_addr]<=w;
    a_q<=(|b_we)&&b_addr==a_addr?~mem[a_addr]:w;
  end
  always_ff @(posedge clk)begin
    logic[31:0] w;
    w=mem[b_addr];
    for(integer l=0;l<4;l=l+1)if(b_we[l])w[l*8+:8]=b_d[l*8+:8];
    if(|b_we)mem[b_addr]<=w;
    b_q<=(|a_we)&&a_addr==b_addr?~mem[b_addr]:w;
  end
`endif
endmodule

// SOURCE-ONLY shared-WRAM prototype. Adapted from the qualified private
// layout above without changing that implementation. Full32KiB, both CPU/
// fabric ports, byte masks and SYS publication remain the proposed contract.
// Native DENSE uses four6556x10 banks; the default remains the old primitive.
// Enabled equivalence/mutant, combined deadlines, measured cost and STA OPEN.
module arm7_wram_shared #(parameter bit DENSE = 1'b0) (
  input logic clk, clk2,
  input logic [12:0] a_addr, b_addr,
  input logic [3:0] a_we, b_we,
  input logic [31:0] a_d, b_d,
  output logic [31:0] a_q, b_q
);
`ifdef ALTERA_RESERVED_QIS
  generate if (DENSE) begin : g_dense
  logic epoch=1'b0, seen=1'b0;
  wire mid=epoch!=seen;
  always_ff @(posedge clk) epoch<=!epoch;
  always_ff @(posedge clk2) seen<=epoch;
  wire [12:0] agroup=a_addr/13'd5, bgroup=b_addr/13'd5;
  wire [2:0] aslot=3'(a_addr%13'd5), bslot=3'(b_addr%13'd5);
  logic [2:0] asq=3'd0, bsq=3'd0;
  logic [31:0] adq=32'd0, bdq=32'd0, amq=32'd0, bmq=32'd0;
  wire [31:0] amask={{8{a_we[3]}},{8{a_we[2]}},{8{a_we[1]}},{8{a_we[0]}}};
  wire [31:0] bmask={{8{b_we[3]}},{8{b_we[2]}},{8{b_we[1]}},{8{b_we[0]}}};
  always_ff @(posedge clk2) if(!mid) begin
    asq<=aslot;bsq<=bslot;adq<=a_d;bdq<=b_d;amq<=amask;bmq<=bmask;
  end
  function automatic [9:0] field(input logic [31:0] data,
                                  input logic [2:0] slot,input integer bank);
    if(slot==3'd4) return {data[bank*8+:8],2'b00};
    if(slot==3'(bank)) return {8'd0,data[bank*10+:2]};
    if(slot<3'(bank)) return 10'(data>>(bank*10-8));
    return 10'(data>>(bank*10));
  endfunction
  function automatic [31:0] expand(input logic [9:0] data,
                                    input logic [2:0] slot,input integer bank);
    if(slot==3'd4) return {24'd0,data[9:2]}<<(bank*8);
    if(slot==3'(bank)) return {30'd0,data[1:0]}<<(bank*10);
    if(slot<3'(bank)) return {22'd0,data}<<(bank*10-8);
    return {22'd0,data}<<(bank*10);
  endfunction
  wire [31:0] aq[0:3],bq[0:3];
  genvar bank;
  for(bank=0;bank<4;bank=bank+1)begin:g_bank
    wire [12:0] ar = {agroup[10:0],2'b00} + (aslot == 3'd4 ? 13'(bank) : {10'd0,aslot});
    wire [12:0] br = {bgroup[10:0],2'b00} + (bslot == 3'd4 ? 13'(bank) : {10'd0,bslot});
    logic [12:0] arq=13'd0,brq=13'd0;
    always_ff @(posedge clk2)if(!mid)begin arq<=ar;brq<=br;end
    wire [9:0] qa,qb;
    wire [9:0] a_write_mask=field(amq,asq,bank),b_write_mask=field(bmq,bsq,bank);
    wire [9:0] a_bits=field(adq,asq,bank),b_bits=field(bdq,bsq,bank);
    wire merge_write=arq==brq&&(|a_write_mask)&&(|b_write_mask);
    wire [9:0] merged_mask=a_write_mask | b_write_mask;
    wire [9:0] aword=(qa&~a_write_mask)|(a_bits&a_write_mask);
    wire [9:0] bword=merge_write?
      ((qb&~merged_mask)|(a_bits&a_write_mask&~b_write_mask)|(b_bits&b_write_mask)):
      ((qb&~b_write_mask)|(b_bits&b_write_mask));
    altsyncram #(
      .operation_mode("BIDIR_DUAL_PORT"),.ram_block_type("M10K"),.intended_device_family("Cyclone V"),
      // Explicit 1Kx10 slices: estimated seven blocks per bank.
      // No native mapping or timing claim until the enabled fit completes.
      .maximum_depth(1024),
      .width_a(10),.widthad_a(13),.numwords_a(6556),
      .width_b(10),.widthad_b(13),.numwords_b(6556),
      .outdata_reg_a("UNREGISTERED"),.outdata_reg_b("UNREGISTERED"),
      .address_reg_b("CLOCK0"),.indata_reg_b("CLOCK0"),.wrcontrol_wraddress_reg_b("CLOCK0"),
      .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
      .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
      .read_during_write_mode_mixed_ports("OLD_DATA"),
      .power_up_uninitialized("FALSE"),.lpm_type("altsyncram")
    )u_ram(.clock0(clk2),.address_a(mid?arq:ar),.address_b(mid?brq:br),
      .data_a(aword),.data_b(bword),
      .wren_a(mid&&(|a_write_mask)&&!merge_write),.wren_b(mid&&(|b_write_mask)),
      .rden_a(!mid),.rden_b(!mid),.q_a(qa),.q_b(qb));
    assign aq[bank]=expand(qa,asq,bank);
    assign bq[bank]=expand(qb,bsq,bank);
  end
  // The original primitive returns own-port NEW_DATA for byte writes.
  assign a_q=((aq[0]|aq[1]|aq[2]|aq[3])&~amq)|(adq&amq);
  assign b_q=((bq[0]|bq[1]|bq[2]|bq[3])&~bmq)|(bdq&bmq);
  end else begin : g_plain
    nds_tdp_ram #(.AW(13)) u_ram (
      .clk, .a_addr, .a_we, .a_d, .a_q, .b_addr, .b_we, .b_d, .b_q);
  end endgenerate
`else
  // Preserve the literal u_shared.mem importer/capture namespace.
  // DENSE native behavior requires independent vendor-model qualification.
  logic [31:0] mem[0:8191];
  initial for(integer i=0;i<8192;i=i+1)mem[i]=32'd0;
  always_ff @(posedge clk)begin
    logic[31:0] w;
    w=mem[a_addr];
    for(integer l=0;l<4;l=l+1)if(a_we[l])w[l*8+:8]=a_d[l*8+:8];
    if(|a_we)mem[a_addr]<=w;
    a_q<=(|b_we)&&b_addr==a_addr?~mem[a_addr]:w;
  end
  always_ff @(posedge clk)begin
    logic[31:0] w;
    w=mem[b_addr];
    for(integer l=0;l<4;l=l+1)if(b_we[l])w[l*8+:8]=b_d[l*8+:8];
    if(|b_we)mem[b_addr]<=w;
    b_q<=(|a_we)&&a_addr==b_addr?~mem[b_addr]:w;
  end
`endif
endmodule
