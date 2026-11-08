// SPDX-License-Identifier: MIT
// The DS mixer's 32,768 Hz samples, linearly interpolated (docs/phase2-
// integration.md, "Sound in the system"). in_l/in_r are the mixer's output
// registers, the newest sample; in_pre pulses the clock before the next
// one starts to load them (sound out_pre). The output moves from the previous
// sample to the newest over the next 2,048 clocks (one sample late), and holds
// the newest if the next sample is late. hold keeps the output registers for
// the clock crossing, which reads them directly. On clk_sys (67.03 MHz: 2,048
// clocks per DS sample).
`default_nettype none
module nds_audio_interp (
    input wire clk,
    input wire in_pre,
    input wire hold,
    input wire signed [15:0] in_l, in_r,
    output reg signed [15:0] out_l = 0, out_r = 0
);
    reg signed [15:0] p_l = 0, p_r = 0;
    reg [11:0] ph = 0;                     // clocks since the newest sample, up to 2,048
    // p + (c - p) * ph / 2048 as (c * ph + p * (2048 - ph)) >> 11: one DSP block
    // per side ("sum of two 18x18"), no subtractor, multiplier and adder of its own
    wire signed [12:0] nh = 13'sd2048 - $signed({1'b0, ph}), sh = $signed({1'b0, ph});
    (* multstyle = "dsp" *) wire signed [28:0] ml_c = in_l * sh, ml_p = p_l * nh, mr_c = in_r * sh, mr_p = p_r * nh;
    wire signed [29:0] s_l = ml_c + ml_p, s_r = mr_c + mr_p;
    always @(posedge clk) begin
        if (in_pre) begin
            p_l <= in_l; p_r <= in_r; ph <= 0;
        end else if (ph != 12'd2048) ph <= ph + 1'b1;
        if (!hold) begin
            out_l <= s_l[26:11];
            out_r <= s_r[26:11];
        end
    end
    // synthesis translate_off
    // ds.sdc's -hold 1 into p_l/p_r rests on this: the sample a load takes is still there the clock after
    reg pre_q = 0;
    reg signed [15:0] il_q, ir_q;
    always @(posedge clk) begin
        pre_q <= in_pre; il_q <= in_l; ir_q <= in_r;
        if (pre_q && (in_l != il_q || in_r != ir_q)) $error("nds_audio_interp: in_l/in_r changed the clock after an in_pre load");
    end
    // synthesis translate_on
endmodule
`default_nettype wire
