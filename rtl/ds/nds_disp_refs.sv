// nds_disp's affine reference points (BG2/BG3 X/Y of both engines, stepped
// by PostDraw) in MLABs instead of 256 registers. Address {x, i, y}: engine,
// BG (2/3), coordinate. Behaves as the registers did, read and written in
// the same clock:
//   - reads (c_q at c_a: the CPU's merge and the reload copy; s_q at s_a:
//     the sequencer) give the value as it is now, before this edge's writes;
//   - the sequencer's write (p_we) and a CPU write (c_we) of the same
//     reference in one clock: the sequencer's wins (it came later in
//     nds_disp's always block) and the CPU's is lost;
//   - reset sets every reference to 0.
// One write port: a CPU write waits in a small queue (one entry per
// reference; a newer write replaces it) and goes in on a clock without a
// sequencer write. Reads take a queued value; a sequencer write of that
// reference drops it (its value already came from the queue). Two RAM copies
// give the two read ports. Unwritten entries read 0 (valid bits).
module nds_disp_refs #(
    parameter int QD = 4                // queued CPU writes
) (
    input  logic        clk,
    input  logic        rst,
    input  logic [2:0]  c_a,
    output logic [31:0] c_q,
    input  logic        c_we,
    input  logic [31:0] c_wd,
    input  logic [2:0]  s_a,
    output logic [31:0] s_q,
    input  logic        p_we,
    input  logic [2:0]  p_a,
    input  logic [31:0] p_wd
);
    (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] mem_c [0:7];
    (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] mem_s [0:7];
    logic [7:0]    vld = '0;            // written since reset (else reads 0)
    logic [QD-1:0] qv = '0;
    logic [2:0]    qa [QD];
    logic [31:0]   qd [QD];

    // the value of reference a now
    function automatic logic [31:0] now(input logic [2:0] a, input logic [31:0] m);
        logic [31:0] r;
        r = vld[a] ? m : 32'd0;
        for (int k = 0; k < QD; k++) if (qv[k] && qa[k] == a) r = qd[k];
        return r;
    endfunction
    assign c_q = now(c_a, mem_c[c_a]);
    assign s_q = now(s_a, mem_s[s_a]);

    // the write port: the sequencer's write, else the oldest queued one
    logic          dr;                  // a queued write goes in now
    int            dk;
    always_comb begin
        dr = 1'b0; dk = 0;
        for (int k = QD - 1; k >= 0; k--) if (qv[k]) begin dr = !p_we; dk = k; end
    end
    wire        we = !rst && (p_we || dr);
    wire [2:0]  wa = p_we ? p_a : qa[dk];
    wire [31:0] wd = p_we ? p_wd : qd[dk];
    always_ff @(posedge clk) if (we) begin mem_c[wa] <= wd; mem_s[wa] <= wd; end

    always_ff @(posedge clk) begin
        if (rst) begin
            vld <= '0; qv <= '0;
        end else begin : upd
            logic done;
            if (we) vld[wa] <= 1'b1;
            if (dr) qv[dk] <= 1'b0;
            // the sequencer's write supersedes a queued write of its reference
            if (p_we) for (int k = 0; k < QD; k++) if (qa[k] == p_a) qv[k] <= 1'b0;
            // a CPU write (lost to a sequencer write of the same reference):
            // replaces its reference's queued value, else takes a free entry
            done = !c_we || (p_we && p_a == c_a);
            for (int k = 0; k < QD; k++)
                if (!done && qv[k] && qa[k] == c_a && !(dr && dk == k)) begin
                    qd[k] <= c_wd; done = 1'b1;
                end
            for (int k = 0; k < QD; k++)
                if (!done && (!qv[k] || (dr && dk == k))) begin
                    qv[k] <= 1'b1; qa[k] <= c_a; qd[k] <= c_wd; done = 1'b1;
                end
`ifndef ALTERA_RESERVED_QIS
            if (!done) $display("nds_disp_refs: CPU write queue full (a write is lost)");
`endif
        end
    end
`ifndef ALTERA_RESERVED_QIS
    // the queue's depth relies on CPU writes (through the bus fabric) being
    // at least two clocks apart: a Q_POST burst blocks the port for eight
    logic c_we_q = 1'b0;
    always_ff @(posedge clk) begin
        c_we_q <= c_we && !rst;
        if (!rst && c_we && c_we_q) $display("nds_disp_refs: CPU writes in consecutive clocks");
    end
`endif
endmodule
