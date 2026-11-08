// IPC: IPCSYNC (0x180), IPCFIFOCNT (0x184), IPCFIFOSEND (0x188) and
// IPCFIFORECV (0x4100000) for both CPUs, after melonDS's IO handlers and its
// FIFO template. Both 16-word FIFOs share one RAM (address {sender, index});
// a read of an empty FIFO returns the entry at the read index, as melonDS's
// Peek does, so stale data matches too. Accesses come from one shared port,
// so a push and a pop never meet in one cycle.
module sys_ipc (
    input  logic        clk,
    input  logic        rst,
    input  logic        cpu,        // 0 ARM9, 1 ARM7
    input  logic        sync_we,
    input  logic        cnt_we,
    input  logic        send_we,
    input  logic        recv_re,
    input  logic [3:0]  be,
    input  logic [31:0] wdata,
    output logic [15:0] rd_sync,    // for `cpu`
    output logic [15:0] rd_cnt,
    output logic [31:0] rd_recv,    // the cycle after recv_re
    output logic [2:0]  irq9,       // IRQ 16..18
    output logic [2:0]  irq7
);
    logic [3:0] out   [2];
    logic       irqen [2];
    logic       en [2], rirq [2], sirq [2], err [2];
    logic [3:0] rp [2], wp [2];
    logic       fl [2];             // FIFO f (written by CPU f) holds 16: its count is {fl, wp - rp}
    wire  [3:0] d0 = wp[0] - rp[0], d1 = wp[1] - rp[1];
    logic [4:0] n [2];
    always_comb begin n[0] = {fl[0], d0}; n[1] = {fl[1], d1}; end

    wire o = !cpu;
    wire c = cpu;
    wire s_empty = n[c] == 5'd0, s_full = n[c][4];
    wire r_empty = n[o] == 5'd0, r_full = n[o][4];
    wire [31:0] sval = be == 4'b0011 ? {wdata[15:0], wdata[15:0]} : wdata;

    // FIFO RAM: pushes and the clear's zeroing of entry 0 on the write port
    logic       ram_we;
    logic [4:0] ram_wa;
    logic [31:0] ram_wd;
    always_comb begin
        ram_we = 1'b0; ram_wa = {c, wp[c]}; ram_wd = sval;
        if (send_we && en[c] && !s_full) ram_we = 1'b1;
        if (cnt_we && be[0] && wdata[3]) begin ram_we = 1'b1; ram_wa = {c, 4'd0}; ram_wd = '0; end
    end
    sys_ram #(.W(32), .AW(5)) u_fifo (
        .clk, .we(ram_we), .waddr(ram_wa), .wdata(ram_wd),
        .raddr({o, rp[o]}), .rdata(rd_recv));

    logic [2:0] ir [2];
    always_comb begin
        ir[0] = '0; ir[1] = '0;
        if (sync_we && be[1] && wdata[13] && irqen[o]) ir[o][0] = 1'b1;
        if (cnt_we && be[0] && wdata[2] && !sirq[c] && (s_empty || wdata[3])) ir[c][1] = 1'b1;
        if (cnt_we && be[1] && wdata[10] && !rirq[c] && !r_empty) ir[c][2] = 1'b1;
        if (send_we && en[c] && !s_full && s_empty && rirq[o]) ir[o][2] = 1'b1;
        if (recv_re && en[c] && n[o] == 5'd1 && sirq[o]) ir[o][1] = 1'b1;
    end
    assign irq9 = ir[0];
    assign irq7 = ir[1];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 2; i++) begin
                out[i] <= '0; irqen[i] <= 1'b0; en[i] <= 1'b0; rirq[i] <= 1'b0;
                sirq[i] <= 1'b0; err[i] <= 1'b0; rp[i] <= '0; wp[i] <= '0; fl[i] <= 1'b0;
            end
        end else begin
            if (sync_we && be[1]) begin out[c] <= wdata[11:8]; irqen[c] <= wdata[14]; end
            if (cnt_we) begin
                if (be[0]) begin
                    sirq[c] <= wdata[2];
                    if (wdata[3]) begin rp[c] <= '0; wp[c] <= '0; fl[c] <= 1'b0; end
                end
                if (be[1]) begin
                    rirq[c] <= wdata[10]; en[c] <= wdata[15];
                    if (wdata[14]) err[c] <= 1'b0;
                end
            end
            if (send_we && en[c]) begin
                if (s_full) err[c] <= 1'b1;
                else begin wp[c] <= wp[c] + 4'd1; fl[c] <= n[c] == 5'd15; end
            end
            if (recv_re && en[c]) begin
                if (r_empty) err[c] <= 1'b1;
                else begin rp[o] <= rp[o] + 4'd1; fl[o] <= 1'b0; end
            end
        end
    end

    assign rd_sync = {1'b0, irqen[c], 2'b00, out[c], 4'd0, out[o]};
    assign rd_cnt  = {en[c], err[c], 3'd0, rirq[c], r_full && !r_empty, r_empty,
                      5'd0, sirq[c], s_full && !s_empty, s_empty};
endmodule
