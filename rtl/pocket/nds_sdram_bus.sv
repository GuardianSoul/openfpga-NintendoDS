// SPDX-License-Identifier: MIT
// The DS core's SDRAM bus (docs/phase2-integration.md, "Memory-system merge"
// M1): nds_sdram_mc on clk_mem behind one fixed-priority arbiter, with one
// crossing per client. Clients keep their contracts:
//   nds_sdram_xport  a clk_sys client with nds_x2b's contract (s_req held
//                    until a one-clock s_ack, s_quad a QW-word read; the
//                    read's words follow on s_rvalid, at up to one per clk_sys)
//   nds_sdram_bport  a clk_bus client with nds_sdram's contract (c_valid held
//                    until a one-clock c_ready; a quad read's 4 words on
//                    r_valid, one per clk_bus)
// clk_sys = 2 x clk_bus, clk_mem = 3 x clk_bus, one PLL with aligned edges:
// each request crosses as a held bundle and a toggle (the closest edge pair
// is 4.97 ns, timed). Read words come back through a small dual-clock FIFO
// per client, or (SHARED = 1) through nds_sdram_words, one FIFO per read
// clock shared by its clients: the arbiter returns one access's words at a
// time and in order, and every client takes each word as it arrives, so a
// FIFO of {client, word} demultiplexed on the read side delivers the same
// words on the same cycles (fit #314: the five per-client FIFOs were five
// M10K).
`default_nettype none

// ---------------------------------------------------------------- arbiter
// Ports 0..N-1, lower index first. A port's request (m_*, clk_mem) is held
// until m_take; its read words come back on w_valid[port] in order.
// HURRY: a port whose m_hurry is set (its client is near a display
// deadline) goes before every port but 0, and a write chain in progress
// ends early for it as for port 0.
module nds_sdram_bus #(parameter integer N = 6,
    parameter integer OPEN = 0,          // nds_sdram_mc OPEN: reads leave their rows open
    parameter integer OUT_REG = 0,       // nds_sdram_mc OUT_REG: a register stage before the pins
    parameter integer HURRY = 0) (       // 1: m_hurry promotes a port (above)
    input  wire [N-1:0]      m_hurry,       // HURRY: the port's client is near its deadline (clk_mem, synchronised)
    input  wire              clk,           // clk_mem
    input  wire              init,
    output wire              ready,
    input  wire [N-1:0]      m_valid,
    input  wire [N-1:0]      m_we,
    input  wire [N*24-1:0]   m_addr,
    input  wire [N*4-1:0]    m_n,
    input  wire [N*32-1:0]   m_wdata,
    input  wire [N*4-1:0]    m_be,
    output reg  [N-1:0]      m_take = 0,
    output reg  [N-1:0]      w_valid = 0,
    output reg  [31:0]       w_data = 0,
    // the controller's write chain and pins
    output wire              ref_late,      // (diagnostics) nds_sdram_mc ref_owed > 1
    input  wire              bw_valid,
    input  wire [23:0]       bw_addr,
    input  wire [31:0]       bw_data,
    output wire              bw_read,
    inout  wire [15:0]       SDRAM_DQ,
    output wire [12:0]       SDRAM_A,
    output wire [1:0]        SDRAM_BA,
    output wire              SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE, SDRAM_CLK
);
    reg [$clog2(N)-1:0] pick;
    reg any;
    wire [N-1:0] wait_p = m_valid & ~m_take;
    wire [N-1:0] hot = HURRY != 0 ? wait_p & (m_hurry | N'(1)) : {N{1'b0}};   // port 0 or a hurried port waits
    always @* begin
        pick = 0; any = 0;
        for (integer i = N - 1; i >= 0; i = i - 1)
            if (wait_p[i]) begin pick = i[$clog2(N)-1:0]; any = 1; end
        if (hot != 0)
            for (integer i = N - 1; i >= 0; i = i - 1)
                if (hot[i]) pick = i[$clog2(N)-1:0];
    end
    // the grant: one port held until the controller has taken its request
    reg g_v = 0;
    reg [$clog2(N)-1:0] g = 0;
    // the granted port's bank and row ({bank, row} = addr[22:8]), copied at
    // the grant: the port holds its request until taken, so this is
    // m_addr[g]'s while g_v (checked below); the controller's ACTIVE takes
    // them from here instead of through the port mux
    reg [14:0] g_rb = 0;
`ifndef ALTERA_RESERVED_QIS
    always @(posedge clk)
        if (g_v && g_rb !== m_addr[g*24+8 +: 15])
            $display("nds_sdram_bus: ERROR: the grant's bank/row copy %h is not port %0d's %h", g_rb, g, m_addr[g*24+8 +: 15]);
`endif
    wire c_ready, r_valid, r_last;
    wire [31:0] r_data;
    nds_sdram_mc #(.OPEN(OPEN), .OUT_REG(OUT_REG)) mc (.clk, .init, .ready,
        .c_valid(g_v && !c_ready), .c_hurry(wait_p[0] || (HURRY != 0 && (wait_p & m_hurry) != 0)), .c_we(m_we[g]), .c_addr(m_addr[g*24 +: 24]), .c_rb(g_rb), .c_n(m_n[g*4 +: 4]),
        .c_wdata(m_wdata[g*32 +: 32]), .c_be(m_be[g*4 +: 4]), .c_ready,
        .r_valid, .r_data, .r_last, .bw_valid, .bw_addr, .bw_data, .bw_read, .ref_late,
        .SDRAM_DQ, .SDRAM_A, .SDRAM_BA, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_nWE, .SDRAM_nRAS, .SDRAM_nCAS,
        .SDRAM_CKE, .SDRAM_CLK);
    // owners of the reads in flight, in order (the controller serves one
    // access at a time, so at most two are outstanding)
    reg [$clog2(N)-1:0] own [0:3];
    reg [1:0] own_r = 0, own_w = 0;
    always @(posedge clk) begin
        m_take <= 0; w_valid <= 0;
        if (c_ready) begin
            g_v <= 1'b0; m_take[g] <= 1'b1;
            if (!m_we[g]) begin own[own_w] <= g; own_w <= own_w + 1'b1; end
        end else if (!g_v && any) begin g_v <= 1'b1; g <= pick; g_rb <= m_addr[pick*24+8 +: 15]; end
        if (r_valid) begin
            w_valid[own[own_r]] <= 1'b1; w_data <= r_data;
            if (r_last) own_r <= own_r + 1'b1;
        end
        if (init) begin own_r <= 0; own_w <= 0; g_v <= 1'b0; end
    end
endmodule

// ------------------------------------------------- a clk_sys client port
module nds_sdram_xport #(parameter integer QW = 4, parameter bit SHARED = 0) (
    input  wire        clk_sys, clk_mem, reset,     // reset on clk_sys
    // clk_sys: nds_x2b's contract
    input  wire        s_req, s_we, s_quad,
    input  wire [23:0] s_addr,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_be,
    output reg         s_ack = 0,
    output reg         s_rvalid = 0,
    output reg  [31:0] s_rdata = 0,
    // clk_mem: to the arbiter
    output wire        m_valid,
    // the request itself: views of the held b_* (see the mem side)
    output wire        m_we,
    output wire [23:0] m_addr,
    output wire [3:0]  m_n,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_be,
    input  wire        m_take,
    input  wire        w_valid,         // clk_mem; SHARED: clk_sys, from nds_sdram_words
    input  wire [31:0] w_data
);
    // sys side: one request held in b_* until the mem side has taken it
    reg req_t = 0, busy = 0, take_seen = 0;
    reg take_t = 0;
    reg b_we = 0, b_quad = 0;
    reg [23:0] b_addr = 0;
    reg [31:0] b_wdata = 0;
    reg [3:0] b_be = 0;
    always @(posedge clk_sys) begin
        s_ack <= 0;
        if (reset) begin busy <= 0; take_seen <= take_t; end
        else begin
            if (busy && take_t != take_seen) begin busy <= 0; take_seen <= take_t; end
            if (!busy && s_req && !s_ack) begin
                busy <= 1; s_ack <= 1; req_t <= !req_t;
                b_we <= s_we; b_quad <= s_quad; b_addr <= s_addr; b_wdata <= s_wdata; b_be <= s_be;
            end
        end
    end
    // The arbiter reads a request only once it has granted it: m_valid rises
    // on the first clk_mem edge after req_t flips, the grant (g_v) one edge
    // later, and nds_sdram_mc takes the fields on the edge after that. The
    // b_* registers hold from req_t's flip until the take has come back
    // (busy), so m_* are views of them: a multicycle path (build_ds.sh)
    // instead of a clk_mem copy.
    // req_t is sampled by one flop (req_s) and nothing else: a flip seen on
    // the clk_mem edge it coincides with (a hold race, #519: -0.100 ns) or on
    // the next is a request one edge earlier or later, either within the b_*
    // window above. Two samplers (the old req_seen and m_valid) could split
    // on that edge and re-issue the request after its take. m_valid is the
    // flip not yet taken: take_t toggles on the take, as req_seen did.
    reg req_s = 0;
    always @(posedge clk_mem) begin
        req_s <= req_t;
        if (m_take) take_t <= !take_t;
    end
    assign m_valid = req_s != take_t;
    assign m_we = b_we; assign m_addr = b_addr; assign m_n = b_we ? 4'd1 : b_quad ? 4'(QW) : 4'd1;
    assign m_wdata = b_wdata; assign m_be = b_be;
    // read words back to clk_sys
    wire f_valid;
    wire [31:0] f_q;
    generate if (SHARED) begin : g_sh
        assign f_valid = w_valid; assign f_q = w_data;
    end else begin : g_own
        nds_dcfifo #(.W(32), .A(4)) words (.wclk(clk_mem), .wreset(1'b0), .wr(w_valid), .wdata(w_data), .full(), .overflow(),
            .rclk(clk_sys), .rd(f_valid), .valid(f_valid), .rdata(f_q));
    end endgenerate
    always @(posedge clk_sys) begin
        s_rvalid <= f_valid; s_rdata <= f_q;
    end
endmodule

// ------------------------------------------------- a clk_bus client port
// SYNC_TAKE: take_t reaches clk_bus through two flops (a clean crossing with
// margin, two clk_bus later per handshake) instead of one compare (one
// clk_mem period at its tightest: #579 -0.415 ns). For clients whose timing
// the DS doesn't see (the bridge-write drain).
module nds_sdram_bport #(parameter bit SHARED = 0, parameter bit SYNC_TAKE = 0) (
    input  wire        clk_bus, clk_mem, reset,     // reset on clk_bus
    // clk_bus: nds_sdram's client contract
    input  wire        c_valid, c_write, c_quad,
    input  wire [23:0] c_addr,
    input  wire [31:0] c_wdata,
    input  wire [3:0]  c_be,
    output reg         c_ready = 0,
    output reg         r_valid = 0,
    output reg  [31:0] r_data = 0,
    // clk_mem
    output wire        m_valid,
    // the request itself: views of the held b_* (see the mem side)
    output wire        m_we,
    output wire [23:0] m_addr,
    output wire [3:0]  m_n,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_be,
    input  wire        m_take,
    input  wire        w_valid,
    input  wire [31:0] w_data
);
    reg req_t = 0, busy = 0, take_seen = 0, take_t = 0;
    (* async_reg = "true" *) reg take_s0 = 0, take_s1 = 0;
    always @(posedge clk_bus) begin take_s0 <= take_t; take_s1 <= take_s0; end
    wire take_b = SYNC_TAKE ? take_s1 : take_t;   // take_t as clk_bus sees it
    reg b_we = 0, b_quad = 0;
    reg [23:0] b_addr = 0;
    reg [31:0] b_wdata = 0;
    reg [3:0] b_be = 0;
    always @(posedge clk_bus) begin
        c_ready <= 0;
        if (reset) begin busy <= 0; take_seen <= take_b; end
        else begin
            if (busy && take_b != take_seen) begin busy <= 0; take_seen <= take_b; c_ready <= 1; end
            else if (!busy && c_valid && !c_ready) begin
                busy <= 1; req_t <= !req_t;
                b_we <= c_write; b_quad <= c_quad; b_addr <= c_addr; b_wdata <= c_wdata; b_be <= c_be;
            end
        end
    end
`ifndef ALTERA_RESERVED_QIS
    // Hold request fields until c_ready; byte enables and data apply only to
    // writes. The shared port may forward another client's BE during a read.
    always @(posedge clk_bus)
        if (!reset && busy && take_b == take_seen &&
            (!c_valid || c_write != b_we || c_quad != b_quad || c_addr != b_addr ||
             (b_we && (c_be != b_be || c_wdata != b_wdata))))
            $display("nds_sdram_bport: ERROR: the client's request changed before c_ready (%m) at %0t", $time);
`endif
    // The arbiter reads a request only once it has granted it: m_valid rises
    // on the first clk_mem edge after req_t flips, the grant (g_v) one edge
    // later, and nds_sdram_mc takes the fields on the edge after that. The
    // b_* registers hold from req_t's flip until the take has come back
    // (busy), so m_* are views of them: a multicycle path (build_ds.sh)
    // instead of a clk_mem copy.
    // req_t is sampled by one flop (req_s) and nothing else: a flip seen on
    // the clk_mem edge it coincides with (a hold race, #519: -0.100 ns) or on
    // the next is a request one edge earlier or later, either within the b_*
    // window above. Two samplers (the old req_seen and m_valid) could split
    // on that edge and re-issue the request after its take. m_valid is the
    // flip not yet taken: take_t toggles on the take, as req_seen did.
    reg req_s = 0;
    always @(posedge clk_mem) begin
        req_s <= req_t;
        if (m_take) take_t <= !take_t;
    end
    assign m_valid = req_s != take_t;
    // the client holds c_* from the request until c_ready, after the take
    // (checked above, in simulation: hg-title, kh-plaza, mkds-race clean), so
    // the arbiter reads them directly; b_* remain only for that check
    // (synthesis drops them). build_ds.sh times c_* -> clk_mem as b_* were.
    assign m_we = c_write; assign m_addr = c_addr; assign m_n = (!c_write && c_quad) ? 4'd4 : 4'd1;
    assign m_wdata = c_wdata; assign m_be = c_be;
    wire f_valid;
    wire [31:0] f_q;
    generate if (SHARED) begin : g_sh
        assign f_valid = w_valid; assign f_q = w_data;
    end else begin : g_own
        nds_dcfifo #(.W(32), .A(3)) words (.wclk(clk_mem), .wreset(1'b0), .wr(w_valid), .wdata(w_data), .full(), .overflow(),
            .rclk(clk_bus), .rd(f_valid), .valid(f_valid), .rdata(f_q));
    end endgenerate
    always @(posedge clk_bus) begin
        r_valid <= f_valid; r_data <= f_q;
    end
endmodule

// ------------------------------------- read words for SHARED client ports
// The arbiter's read words for the clients in SEL (one bit per arbiter
// port), tagged with the port, to clock rclk; o_valid[port] with o_data on
// the cycle a per-client FIFO would have shown them.
module nds_sdram_words #(parameter integer N = 6, parameter [N-1:0] SEL = 0, parameter integer A = 4) (
    input  wire          clk_mem,
    input  wire [N-1:0]  w_valid,
    input  wire [31:0]   w_data,
    input  wire          rclk,
    output wire [N-1:0]  o_valid,
    output wire [31:0]   o_data
);
    localparam integer IW = $clog2(N);
    reg [IW-1:0] id;
    always @* begin
        id = 0;
        for (integer i = 0; i < N; i = i + 1) if (SEL[i] && w_valid[i]) id = i[IW-1:0];
    end
    wire f_valid;
    wire [IW+31:0] f_q;
    nds_dcfifo #(.W(IW + 32), .A(A)) words (.wclk(clk_mem), .wreset(1'b0), .wr(|(w_valid & SEL)), .wdata({id, w_data}),
        .full(), .overflow(), .rclk(rclk), .rd(f_valid), .valid(f_valid), .rdata(f_q));
    genvar i;
    generate for (i = 0; i < N; i = i + 1) begin : g_o
        assign o_valid[i] = SEL[i] && f_valid && f_q[IW+31:32] == i;
    end endgenerate
    assign o_data = f_q[31:0];
endmodule
`default_nettype wire
