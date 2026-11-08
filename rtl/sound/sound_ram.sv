// Sound engine RAMs (docs/sound.md). One write port and one registered read
// port each, so every one maps to M10K or MLAB. Reading an address in the
// cycle it is written returns the old word. ce is the engine's clock enable
// (rtl/ds runs it at half of clk_sys).

module sound_ram #(
    parameter int AW = 7,
    parameter int DW = 34,
    parameter bit ADPCM = 0         // words 128-216 start as the ADPCM step table (the FIFO RAM)
) (
    input  logic          clk,
    input  logic          ce,
    input  logic          we,
    input  logic [AW-1:0] wa,
    input  logic [DW-1:0] wd,
    input  logic [AW-1:0] ra,
    output logic [DW-1:0] q
);
    // IMA-ADPCM step table (89 entries), for the FIFO RAM's initial contents.
    function automatic logic [14:0] adpcm_step(input logic [6:0] i);
        unique case (i)
            7'd0: return 15'd7; 7'd1: return 15'd8; 7'd2: return 15'd9; 7'd3: return 15'd10; 7'd4: return 15'd11; 7'd5: return 15'd12; 7'd6: return 15'd13; 7'd7: return 15'd14;
            7'd8: return 15'd16; 7'd9: return 15'd17; 7'd10: return 15'd19; 7'd11: return 15'd21; 7'd12: return 15'd23; 7'd13: return 15'd25; 7'd14: return 15'd28; 7'd15: return 15'd31;
            7'd16: return 15'd34; 7'd17: return 15'd37; 7'd18: return 15'd41; 7'd19: return 15'd45; 7'd20: return 15'd50; 7'd21: return 15'd55; 7'd22: return 15'd60; 7'd23: return 15'd66;
            7'd24: return 15'd73; 7'd25: return 15'd80; 7'd26: return 15'd88; 7'd27: return 15'd97; 7'd28: return 15'd107; 7'd29: return 15'd118; 7'd30: return 15'd130; 7'd31: return 15'd143;
            7'd32: return 15'd157; 7'd33: return 15'd173; 7'd34: return 15'd190; 7'd35: return 15'd209; 7'd36: return 15'd230; 7'd37: return 15'd253; 7'd38: return 15'd279; 7'd39: return 15'd307;
            7'd40: return 15'd337; 7'd41: return 15'd371; 7'd42: return 15'd408; 7'd43: return 15'd449; 7'd44: return 15'd494; 7'd45: return 15'd544; 7'd46: return 15'd598; 7'd47: return 15'd658;
            7'd48: return 15'd724; 7'd49: return 15'd796; 7'd50: return 15'd876; 7'd51: return 15'd963; 7'd52: return 15'd1060; 7'd53: return 15'd1166; 7'd54: return 15'd1282; 7'd55: return 15'd1411;
            7'd56: return 15'd1552; 7'd57: return 15'd1707; 7'd58: return 15'd1878; 7'd59: return 15'd2066; 7'd60: return 15'd2272; 7'd61: return 15'd2499; 7'd62: return 15'd2749; 7'd63: return 15'd3024;
            7'd64: return 15'd3327; 7'd65: return 15'd3660; 7'd66: return 15'd4026; 7'd67: return 15'd4428; 7'd68: return 15'd4871; 7'd69: return 15'd5358; 7'd70: return 15'd5894; 7'd71: return 15'd6484;
            7'd72: return 15'd7132; 7'd73: return 15'd7845; 7'd74: return 15'd8630; 7'd75: return 15'd9493; 7'd76: return 15'd10442; 7'd77: return 15'd11487; 7'd78: return 15'd12635; 7'd79: return 15'd13899;
            7'd80: return 15'd15289; 7'd81: return 15'd16818; 7'd82: return 15'd18500; 7'd83: return 15'd20350; 7'd84: return 15'd22385; 7'd85: return 15'd24623; 7'd86: return 15'd27086; 7'd87: return 15'd29794;
            7'd88: return 15'd32767;
            default: return 15'd0;
        endcase
    endfunction
    logic [DW-1:0] mem [0:(1<<AW)-1] /*verilator public_flat_rw*/;
    // {step/4 + step/8, step}: the decode adds step/8 or the pair as one term
    // (sound.sv vsum); indexes 89-127 are 0, so a step read there gives 0
    initial if (ADPCM) for (int i = 0; i < 128; i++)
        mem[128 + i] = DW'({15'(adpcm_step(7'(i)) >> 2) + 15'(adpcm_step(7'(i)) >> 3), adpcm_step(7'(i))});
    always_ff @(posedge clk) if (ce) begin
        if (we) mem[wa] <= wd;
        q <= mem[ra];
    end
endmodule

// The same RAM, kept out of M10K (the chip's binding block): shallow or
// narrow tables (docs/sound.md, "M10K"). The engine does not depend on what
// a read in a write's cycle returns (the full suite passes with new-data
// reads too), so no_rw_check.
module sound_mlab #(
    parameter int AW = 7,
    parameter int DW = 2,
    parameter     STYLE = "MLAB, no_rw_check"   // "M10K": old data on a same-address read
) (
    input  logic          clk,
    input  logic          ce,
    input  logic          we,
    input  logic [AW-1:0] wa,
    input  logic [DW-1:0] wd,
    input  logic [AW-1:0] ra,
    output logic [DW-1:0] q
);
    (* ramstyle = STYLE *) logic [DW-1:0] mem [0:(1<<AW)-1] /*verilator public_flat_rw*/;
    always_ff @(posedge clk) if (ce) begin
        if (we) mem[wa] <= wd;
        q <= mem[ra];
    end
endmodule

// One register word (SOUNDxCNT, SAD, TMR/PNT or LEN; captures: DAD, TMR,
// LEN) of every entry e (channels 0-15, captures 16-17). Written only by
// ARM7 register writes, through byte lanes (Quartus's unrolled template).
module sound_cpu_ram #(
    parameter int AW = 5
) (
    input  logic          clk,
    input  logic          ce,
    input  logic          we,
    input  logic [3:0]    be,
    input  logic [AW-1:0] wa,
    input  logic [31:0]   wd,
    input  logic [AW-1:0] ra,
    output logic [31:0]   q
);
    logic [3:0][7:0] mem [0:(1<<AW)-1] /*verilator public_flat_rw*/;
    always_ff @(posedge clk) if (ce) begin
        if (we) begin
            if (be[0]) mem[wa][0] <= wd[7:0];
            if (be[1]) mem[wa][1] <= wd[15:8];
            if (be[2]) mem[wa][2] <= wd[23:16];
            if (be[3]) mem[wa][3] <= wd[31:24];
        end
        q <= mem[ra];
    end
endmodule

// Run-time words w4-w7 of entry e in one row, through byte lanes: the
// store writes the working set, the ADPCM loop state has lanes of its own.
module sound_run_ram (
    input  logic         clk,
    input  logic         ce,
    input  logic         we,
    input  logic [19:0]  be,
    input  logic [4:0]   wa,
    input  logic [159:0] wd,
    input  logic [4:0]   ra,
    output logic [159:0] q
);
    logic [19:0][7:0] mem [0:31] /*verilator public_flat_rw*/;
    always_ff @(posedge clk) if (ce) begin
        if (we) begin
            if (be[0]) mem[wa][0] <= wd[7:0];
            if (be[1]) mem[wa][1] <= wd[15:8];
            if (be[2]) mem[wa][2] <= wd[23:16];
            if (be[3]) mem[wa][3] <= wd[31:24];
            if (be[4]) mem[wa][4] <= wd[39:32];
            if (be[5]) mem[wa][5] <= wd[47:40];
            if (be[6]) mem[wa][6] <= wd[55:48];
            if (be[7]) mem[wa][7] <= wd[63:56];
            if (be[8]) mem[wa][8] <= wd[71:64];
            if (be[9]) mem[wa][9] <= wd[79:72];
            if (be[10]) mem[wa][10] <= wd[87:80];
            if (be[11]) mem[wa][11] <= wd[95:88];
            if (be[12]) mem[wa][12] <= wd[103:96];
            if (be[13]) mem[wa][13] <= wd[111:104];
            if (be[14]) mem[wa][14] <= wd[119:112];
            if (be[15]) mem[wa][15] <= wd[127:120];
            if (be[16]) mem[wa][16] <= wd[135:128];
            if (be[17]) mem[wa][17] <= wd[143:136];
            if (be[18]) mem[wa][18] <= wd[151:144];
            if (be[19]) mem[wa][19] <= wd[159:152];
        end
        q <= mem[ra];
    end
endmodule

// Capture buffers: 4 words per unit, written a sample at a time through
// byte lanes. Stays in M10K: as MLAB Quartus builds it from flops (nds-fit
// #319: 96 ALMs, 288 registers for one M10K).
module sound_capbuf (
    input  logic        clk,
    input  logic        ce,
    input  logic        we,
    input  logic [3:0]  be,
    input  logic [2:0]  wa,
    input  logic [31:0] wd,
    input  logic [2:0]  ra,
    output logic [31:0] q
);
    logic [3:0][7:0] mem [0:7] /*verilator public_flat_rw*/;
    always_ff @(posedge clk) if (ce) begin
        if (we) begin
            if (be[0]) mem[wa][0] <= wd[7:0];
            if (be[1]) mem[wa][1] <= wd[15:8];
            if (be[2]) mem[wa][2] <= wd[23:16];
            if (be[3]) mem[wa][3] <= wd[31:24];
        end
        q <= mem[ra];
    end
endmodule

// IMA-ADPCM step for (index, nibble bits 2:0): {next index, difference}.
// The difference is melonDS's sum step/8 + (n0 ? step/4) + (n1 ? step/2) +
// (n2 ? step), each term truncated; the next index is clamped to 0..88.
// Indexes 89-127 give 0, as the 1024-word ROM this replaced did (3 M10K;
// docs/sound.md, "M10K"). The step comes from the FIFO RAM's upper half
// (sound_ram ADPCM = 1), read the cycle before with ra registered beside it,
// so the result is valid when the old registered ROM's was.
module sound_adpcm_step (
    input  logic [14:0] step,       // adpcm_step(ra[9:3]), from the RAM
    input  logic [9:0]  ra,         // {index, nibble bits 2:0}, registered with the RAM read
    output logic [22:0] q
);
    wire [15:0] diff = {4'd0, step[14:3]} + (ra[0] ? {3'd0, step[14:2]} : 16'd0)
                     + (ra[1] ? {2'd0, step[14:1]} : 16'd0) + (ra[2] ? {1'd0, step} : 16'd0);
    wire [7:0]  ni   = {1'b0, ra[9:3]} + (ra[2] ? {5'd0, ra[1:0], 1'b0} + 8'd2 : 8'hFF);
    wire [6:0]  nx   = ni[7] ? 7'd0 : ni[6:0] > 7'd88 ? 7'd88 : ni[6:0];
    assign q = ra[9:3] > 7'd88 ? 23'd0 : {nx, diff};
endmodule
