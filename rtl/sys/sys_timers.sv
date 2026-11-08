// All eight timers (0x100..0x10F of both CPUs) on one engine and one RAM (study: "sequential peripherals"). Each entry is
// brought up to date when it is visited: the free-running slot, or at once for the CPU's read or write of it, so the
// CPU always sees the exact count. A visit adds the ticks since the last one (`gc` - last): F/1 all of them, F/64, F/256,
// F/1024 one if the free-running divider wrapped in them, a cascaded timer one if the timer below overflowed.
// IRQs and cascades come at the overflow tick (docs/timer-exact-plan.md): a visit that finds the next overflow within 16
// ticks arms the entry's target tick (`tg`, against the 4-bit tick count `gt`), or, for a cascaded timer at 0xFFFF, its
// chain to the timer below; the overflow fires there. The visit after it wraps the RAM entry as before (`fd`: already
// fired). An overflow a visit finds unfired still comes out at that visit, late (none on the bench: `miss`).
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
    wire  [3:0] gt = dv[3:0];       // ticks (the prescaler's: it steps on every tick); the RAM keeps them as `last`
    wire  [3:0] gc = gt;
    logic [7:0] c_p;                // the timer below has overflowed
    logic       rst_q;              // (the reset walks the RAM; a register of its own, the chip's reset comes from far)
    logic [3:0] tg [0:7];           // the armed overflow's tick
    logic [7:0] av, ch, en, fd;     // armed; chained to the timer below; IRQ enable; fired, not yet wrapped
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
    wire  [15:0] nc = start ? n_rel : upd;
    assign rdata = {8'd0, cn[4:3], 3'd0, cn[2:0], upd};
    // The look-ahead runs a clock after the visit, from registers (s_*): the entry as written at the visit, the ticks to
    // its next overflow counted from the first tick edge at or after the visit (1 = it). F/1 steps on every tick; F/64..
    // on the tick where dv's low 6, 8, 10 bits wrap, so it overflows there from 0xFFFF; with the tick count `gt` dv's
    // low 4 bits, that is tick 15. Fires come from registers only. The entry is registered as written (nothing more on
    // the visit path); of dv, a register already, the registers keep its wraps for the prescales (s_dw: &dv[5:4],
    // &dv[7:4], &dv[9:4]) and its low 4 (s_gt).
    logic        s_v, s_wr, s_tk, s_f;
    logic [2:0]  s_k, s_dw;
    logic [15:0] s_nc;
    logic [4:0]  s_cn;
    logic [3:0]  s_gt;
    wire         ones = &s_nc;                          // the counter is 0xFFFF
    logic        near;
    always_comb case (s_cn[1:0])
        2'd0:    near = &s_nc[15:4];
        2'd1:    near = ones && s_dw[0];
        2'd2:    near = ones && s_dw[1];
        default: near = ones && s_dw[2];
    endcase
    wire  [3:0]  togo = ~(s_cn[1:0] == 2'd0 ? s_nc[3:0] : s_gt);   // ticks to go - 1
    wire         run  = s_v && s_cn[4];
    wire         arm  = run && !s_cn[2] && near;
    wire         due  = arm && togo == 4'd0;            // at the visit's tick edge, or this one after a non-tick visit
    // (at the visit's own tick edge, an earlier arm fired it; after a write there it fires here, one clock late: `wlate`)
    wire         now  = due && (!s_tk || s_wr);
    wire         link = run && s_cn[2] && ones;         // the next overflow below steps it over
    logic [7:0]  fire, sk, wv;      // sk: the entry the look-ahead is for; wv: written now (its arm no longer holds)
    logic        dn;                // the timer below fires
    always_comb begin
        sk = s_v ? 8'd1 << s_k : 8'd0;
        wv = wr && !rst_q ? 8'd1 << i : 8'd0;
        dn = 1'b0;
        for (int k = 0; k < 8; k++) begin
            if (k[1:0] == 2'd0) dn = 1'b0;
            if (wv[k])               fire[k] = 1'b0;
            else if (sk[k] && s_wr)  fire[k] = now || dn && link;
            else                     fire[k] = tick && av[k] && tg[k] == gt || sk[k] && now || dn && ch[k];
            dn = fire[k];
        end
    end
    wire         late = ovf && !fd[i] && !fire[i] && !rst_q;   // an overflow nothing armed (or fires now: a write's, late)
    always_ff @(posedge clk) begin
        rst_q <= rst;
        irq <= 8'd0;
        if (!acc || rst_q) slot <= slot + 3'd1;
        mem[i] <= rst_q ? '0 : {gc, n_cn, n_rel, nc};
        s_v <= !rst_q; s_k <= i; s_wr <= wr; s_nc <= nc; s_cn <= n_cn; s_tk <= tick; s_gt <= gt;
        s_dw <= {&dv[9:4], &dv[7:4], &dv[5:4]};
        s_f <= fire[i];
        if (rst_q) begin c_p <= 8'd0; av <= 8'd0; ch <= 8'd0; fd <= 8'd0; end
        else begin
            c_p[i] <= 1'b0; fd[i] <= 1'b0;
            if (late && i[1:0] != 2'd3) c_p[i + 3'd1] <= 1'b1;
            if (late && cn[3]) irq[i] <= 1'b1;  // (what was due before a write: the old enable)
            if (s_v && !s_f) begin               // (a fire since the visit: the next visit arms the next one)
                av[s_k] <= arm && !due; ch[s_k] <= link; en[s_k] <= s_cn[3]; tg[s_k] <= s_cn[1:0] == 2'd0 ? s_gt + togo : 4'hF;
            end
            for (int k = 0; k < 8; k++) if (fire[k]) begin
                av[k] <= 1'b0; ch[k] <= 1'b0; fd[k] <= !(3'(k) == i && ovf);   // (this visit wraps it already)
                if (k[1:0] != 2'd3) c_p[k + 1] <= 1'b1;
                if (sk[k] ? s_cn[3] : en[k]) irq[k] <= 1'b1;
            end
        end
    end
    // synthesis translate_off
    int miss /*verilator public_flat*/ = 0;  // overflows that came out at a visit, late
    int wlate /*verilator public_flat*/ = 0; // fired a clock late: a write on the overflow's own tick edge
    wire wl = s_v && s_wr && s_tk && due;    // (by the look-ahead, or by the next visit when a write suppresses that)
    always_ff @(posedge clk) begin
        if (late && !wl) miss <= miss + 1;
        if (wl) wlate <= wlate + 1;
    end
    // synthesis translate_on
endmodule
