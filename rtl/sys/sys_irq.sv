// Interrupt controller for one CPU: IME (0x208), IE (0x210), IF (0x214),
// after melonDS NDS::UpdateIRQ/SetIRQ and the IO write handlers. IE keeps
// all 32 bits as melonDS does; IF bits are set by source pulses and cleared
// by writing 1. A source pulse in the same cycle as a clear wins. Level
// sources (the GX FIFO IRQ, which melonDS re-raises after every IF write)
// are driven as a pulse every cycle the condition holds.
module sys_irq (
    input  logic        clk,
    input  logic        rst,
    input  logic        we,
    input  logic [3:0]  be,
    input  logic [1:0]  sel,        // 0 IME, 1 IE, 2 IF
    input  logic [31:0] wdata,
    input  logic [31:0] src,        // set pulses, bit = IRQ number
    output logic [31:0] rd_ime,
    output logic [31:0] rd_ie,
    output logic [31:0] rd_if,
    output logic        irq
);
    logic        ime;
    logic [31:0] ie, iflag, bm;
    always_comb for (int i = 0; i < 4; i++) bm[i*8 +: 8] = {8{be[i]}};

    always_ff @(posedge clk) begin
        if (rst) begin
            ime <= 1'b0; ie <= '0; iflag <= '0;
        end else begin
            if (we && sel == 2'd0 && be[0]) ime <= wdata[0];
            if (we && sel == 2'd1) ie <= (ie & ~bm) | (wdata & bm);
            iflag <= (iflag & ~((we && sel == 2'd2) ? (wdata & bm) : 32'd0)) | src;
        end
    end

    assign rd_ime = {31'd0, ime};
    assign rd_ie  = ie;
    assign rd_if  = iflag;
    assign irq    = ime && |(ie & iflag);
endmodule
