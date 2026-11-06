// The Pocket's 256 KiB async SRAM (128K x 16) as 32-bit words on
// clk_sys (67.03 MHz, 14.9 ns): docs/phase2-integration.md, "First fit with
// 3D". One access at a time; a request is held until done, which also
// carries the read word.
//
// All pin outputs are registered (I/O cell registers) and dq is captured in
// an input register every clock. The timing is Phase 1's hardware
// measurement of this SRAM (phase1-foundation.md, nds-fit #60 run): a read
// sampled 39.8 ns or more after the address passed every round, 29.9 ns
// failed, and WE# needs the same 39.8 ns. So each half's address is held RA
// clocks (44.7 ns) before it is sampled, and WE# is low WP clocks (44.7 ns).
// (The first version assumed a 10 ns part: 2 clocks and a 1-clock WE# pulse,
// which gave a white screen in every game on hardware, #211.)
//   read word:  lo address RA clocks, hi address RA clocks, done the clock after
//   write word: per half with a byte enable set: address (bus released, OE
//               high), data + WE low for WP clocks, WE high (address and data
//               held); the bus is released after the last half
module nds_sram #(
    parameter int RA = 3,           // clocks from a half's address to its sample
    parameter int WP = 3            // clocks WE# is low
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        req,
    input  logic        we,
    input  logic [17:2] addr,
    input  logic [3:0]  be,
    input  logic [31:0] wdata,
    output logic        done,
    output logic [31:0] rdata,
    // pins
    output logic [16:0] sram_a,
    inout  wire  [15:0] sram_dq,
    output logic        sram_oe_n,
    output logic        sram_we_n,
    output logic        sram_ub_n,
    output logic        sram_lb_n
);
    logic [15:0] dq_out, dq_in;
    logic        dq_oe;
    assign sram_dq = dq_oe ? dq_out : 16'bz;
    always_ff @(posedge clk) dq_in <= sram_dq;

    typedef enum logic [2:0] { S_IDLE, S_RL, S_RH, S_RD, S_W0, S_W1, S_W2, S_WD } st_t;
    st_t        st;
    logic [1:0] k;                  // clocks in this read half, or of WE# low
    logic       hi;                 // working on the high half
    logic [15:0] lo_q;
    wire  [1:0] hbe = hi ? be[3:2] : be[1:0];
    wire        hi_needed = be[3:2] != 2'b00;
    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            st <= S_IDLE; sram_oe_n <= 1'b1; sram_we_n <= 1'b1; sram_ub_n <= 1'b1; sram_lb_n <= 1'b1; dq_oe <= 1'b0;
        end else case (st)
            S_IDLE: if (req && !done) begin
                k <= 2'd0;
                if (!we) begin
                    sram_a <= {addr, 1'b0}; sram_oe_n <= 1'b0; sram_ub_n <= 1'b0; sram_lb_n <= 1'b0; st <= S_RL;
                end else begin
                    hi <= be[1:0] == 2'b00;
                    sram_a <= {addr, be[1:0] == 2'b00}; sram_oe_n <= 1'b1; st <= S_W0;
                    sram_ub_n <= be[1:0] == 2'b00 ? !be[3] : !be[1];
                    sram_lb_n <= be[1:0] == 2'b00 ? !be[2] : !be[0];
                end
            end
            S_RL: begin                                         // the lo word is on its way
                k <= k + 2'd1;
                if (k == 2'(RA - 1)) begin sram_a[0] <= 1'b1; k <= 2'd0; st <= S_RH; end   // lo captured at this edge
            end
            S_RH: begin
                if (k == 2'd0) lo_q <= dq_in;
                k <= k + 2'd1;
                if (k == 2'(RA - 1)) st <= S_RD;                // hi captured at this edge
            end
            S_RD: begin
                rdata <= {dq_in, lo_q}; done <= 1'b1;
                sram_oe_n <= 1'b1; sram_ub_n <= 1'b1; sram_lb_n <= 1'b1; st <= S_IDLE;
            end
            S_W0: begin
                dq_oe <= 1'b1; dq_out <= hi ? wdata[31:16] : wdata[15:0]; sram_we_n <= 1'b0; st <= S_W1;
            end
            S_W1: begin                                         // WE# low
                k <= k + 2'd1;
                if (k == 2'(WP - 1)) begin sram_we_n <= 1'b1; k <= 2'd0; st <= S_W2; end
            end
            S_W2: if (!hi && hi_needed) begin
                hi <= 1'b1; sram_a[0] <= 1'b1; sram_ub_n <= !be[3]; sram_lb_n <= !be[2];
                dq_out <= wdata[31:16]; st <= S_WD;             // bus stays driven; WE low next
            end else begin
                dq_oe <= 1'b0; sram_ub_n <= 1'b1; sram_lb_n <= 1'b1; done <= 1'b1; st <= S_IDLE;
            end
            default: begin sram_we_n <= 1'b0; k <= 2'd0; st <= S_W1; end   // S_WD: second half's WE low
        endcase
    end
endmodule
