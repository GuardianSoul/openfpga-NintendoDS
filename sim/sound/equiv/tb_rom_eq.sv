// ADPCM ROM equivalence: rtl/sound's step table in the FIFO RAM (sound_ram
// ADPCM = 1, words 128-216) with sound_adpcm_step after it, read the way
// sound.sv reads it, against the 1024-word ROM it replaced
// (sound_adpcm_rom_ref), every address, with ce toggling;
// sim/sound/equiv/rom_eq.sh builds the reference from git.
module tb_rom_eq;
    logic clk = 0, ce = 0;
    logic [9:0] ra = 0;
    logic [22:0] q_new, q_ref;
    logic [31:0] ff_q;
    logic [9:0]  ra_q;
    sound_ram #(.AW(8), .DW(32), .ADPCM(1)) u_ram (.clk, .ce, .we(1'b0), .wa(8'd0), .wd(32'd0),
        .ra({1'b1, ra[9:3]}), .q(ff_q));
    always_ff @(posedge clk) if (ce) ra_q <= ra;
    sound_adpcm_step    u_new (.step(ff_q[14:0]), .ra(ra_q), .q(q_new));
    sound_adpcm_rom_ref u_ref (.clk, .ce, .ra, .q(q_ref));
    int bad = 0, n = 0;
    always #1 clk = ~clk;
    initial begin
        for (int pass = 0; pass < 2; pass++)
            for (int a = 0; a < 1024; a++) begin
                @(negedge clk); ra = 10'(pass == 0 ? a : (a * 397) % 1024); ce = 1'b1;
                @(negedge clk); ce = 1'b0;
                @(negedge clk);
                n++; if (q_new !== q_ref) begin bad++; if (bad < 5) $display("ra %0d: new %h ref %h", ra, q_new, q_ref); end
            end
        $display("%s: %0d reads, %0d mismatches", bad ? "FAIL" : "PASS", n, bad);
        $finish;
    end
endmodule
