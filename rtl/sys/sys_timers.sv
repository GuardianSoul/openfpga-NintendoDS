// All eight timers (0x100..0x10F of both CPUs) on one engine and one RAM (study: "sequential peripherals"). Each entry is
// brought up to date when it is visited: the free-running slot, or at once for the CPU's read or write of it, so the
// CPU always sees the exact count. A visit adds the ticks since the last one (`gc` - last): F/1 all of them, F/64, F/256,
// F/1024 one if the free-running divider wrapped in them, a cascaded timer one if the timer below overflowed. An
// overflow's IRQ and cascade come out at the visit, up to eight clocks late.
module sys_timers (
    input  logic        clk,
    input  logic        rst,
    input  logic        tick,
    input  logic [9:0]  dv,         // the free-running prescaler
    input  logic        acc,        // the CPU reads or writes a timer
    input  logic [2:0]  acc_i,      // which: {ARM7, timer}
    input  logic        we,
    input  logic [3:0]  be,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,      // {TMCNT_H, TMCNT_L counter}
    output logic [7:0]  irq         // overflow with IRQ enable, one pulse
);
    localparam int W = 16 + 16 + 5 + 4;
    (* ramstyle = "MLAB, no_rw_check" *) logic [W-1:0] mem [0:7];
    logic [2:0] slot;
    logic [3:0] gc;
    logic [7:0] c_p;                // the timer below has overflowed
    logic       rst_q;              // (the reset walks the RAM; a register of its own, the chip's reset comes from far)
    wire  [2:0] i = rst_q ? slot : acc ? acc_i : slot;
    wire  [W-1:0] e = mem[i];
    wire  [15:0] ctr = e[15:0], reload = e[31:16];
    wire  [4:0]  cn  = e[36:32];    // {start, irq enable, cascade, prescale}
    wire  [3:0]  last = e[40:37];
    wire  [3:0]  d = gc - last;
    logic        wrapped;
    always_comb case (cn[1:0])
        2'd1:    wrapped = dv[5:4] == 2'd0 && dv[3:0] < d;
        2'd2:    wrapped = dv[7:4] == 4'd0 && dv[3:0] < d;
        default: wrapped = dv[9:4] == 6'd0 && dv[3:0] < d;
    endcase
    wire  [3:0]  steps = !cn[4] ? 4'd0 : cn[2] ? 4'(c_p[i]) : cn[1:0] == 2'd0 ? d : 4'(wrapped);
    wire  [16:0] n = {1'b0, ctr} + {13'd0, steps};
    wire         ovf = n[16];
    wire  [15:0] upd = ovf ? reload + 16'(n[3:0]) : n[15:0];
    wire         wr  = acc && we;
    wire         cwr = wr && be[2];
    wire  [15:0] n_rel = wr && be[1:0] == 2'b11 ? wdata[15:0] : reload;
    wire  [4:0]  n_cn  = cwr ? {wdata[23:22], wdata[18:16]} : cn;
    wire         start = cwr && !cn[4] && n_cn[4];
    assign rdata = {8'd0, cn[4:3], 3'd0, cn[2:0], upd};
    always_ff @(posedge clk) begin
        rst_q <= rst;
        if (tick) gc <= gc + 4'd1;
        irq <= 8'd0;
        if (!acc || rst_q) slot <= slot + 3'd1;
        mem[i] <= rst_q ? '0 : {gc, n_cn, n_rel, start ? n_rel : upd};
        if (rst_q) begin c_p <= 8'd0; gc <= 4'd0; end
        else begin
            c_p[i] <= 1'b0;
            if (ovf && i[1:0] != 2'd3) c_p[i + 3'd1] <= 1'b1;
            if (ovf && cn[3]) irq[i] <= 1'b1;   // (what was due before a write: the old enable)
        end
    end
endmodule
