// Experimental event-domain primitive. Not connected to production sound yet.
// Decoders supply the next sample BEFORE its timer event; starvation is explicit.
// Timers retain the 16.75 MHz domain; no output-step sample repetition.
module sound_event_capture #(
    parameter integer TIMER_DIV = 4
) (
    input logic clk, ce, rst,
    input logic [15:0] voice_enable, voice_restart, voice_have,
    input logic [15:0] voice_reload [16],
    input logic signed [15:0] voice_next [16],
    input logic [6:0] voice_volume [16], voice_pan [16],
    input logic [1:0] voice_divider [16],
    input logic [1:0] capture_enable, capture_restart,
    input logic [15:0] capture_reload [2], capture_length [2],
    output logic [15:0] voice_advance, starved,
    output logic [1:0] capture_busy, capture_valid,
    output logic [15:0] capture_data [2]
);
    localparam integer CW = TIMER_DIV > 1 ? $clog2(TIMER_DIV) : 1;
    logic [CW-1:0] divider;
    logic [15:0] timer [16], cap_timer [2], cap_count [2];
    logic signed [15:0] sample_q [16];
    logic tick;
    assign tick = divider == CW'(TIMER_DIV-1);
    always_comb begin
        voice_advance = '0;
        starved = '0;
        for (int c=0;c<16;c++) begin
            if (tick && voice_enable[c] && !voice_restart[c] && timer[c]==16'hffff) begin
                voice_advance[c] = voice_have[c];
                starved[c] = !voice_have[c];
            end
        end
    end
    logic signed [31:0] mixed [2];
    logic signed [63:0] product;
    logic signed [15:0] sample_now;
    logic [7:0] volume_now, pan_now;
    logic [11:0] volume_scaled;
    always_comb begin
        mixed[0]='0; mixed[1]='0;
        product='0; sample_now='0; volume_now='0; pan_now='0; volume_scaled='0;
        for (int c=0;c<16;c++) begin
            // Same-edge channel update precedes capture: no stale mix snapshot.
            sample_now = !voice_enable[c] || voice_restart[c] ? 16'sd0 : voice_advance[c] ? voice_next[c] : sample_q[c];
            volume_now = voice_volume[c]==127 ? 8'd128 : {1'b0,voice_volume[c]};
            pan_now = voice_pan[c]==127 ? 8'd128 : {1'b0,voice_pan[c]};
            case (voice_divider[c])
                0:volume_scaled={volume_now,4'd0};
                1:volume_scaled={1'b0,volume_now,3'd0};
                2:volume_scaled={2'b0,volume_now,2'd0};
                default:volume_scaled={4'b0,volume_now};
            endcase
            product = 64'(sample_now) * $signed({1'b0,volume_scaled}) * $signed(9'd128-{1'b0,pan_now});
            mixed[0] = mixed[0] + 32'(product >>> 10);
            product = 64'(sample_now) * $signed({1'b0,volume_scaled}) * $signed({1'b0,pan_now});
            mixed[1] = mixed[1] + 32'(product >>> 10);
        end
    end
    function automatic logic [15:0] pcm16(input logic signed [31:0] sum);
        logic signed [31:0] half;
        begin
            half = sum >>> 7;
            // DS_SPU_CAPTURE: (sum >> 7) / 2, halved toward zero.
            half = half < 0 ? -((-half) >>> 1) : half >>> 1;
            return half > 32767 ? 16'h7fff : half < -32768 ? 16'h8000 : half[15:0];
        end
    endfunction
    always_ff @(posedge clk) if (ce) begin
        capture_valid <= '0;
        divider <= tick ? '0 : divider + 1'b1;
        for (int c=0;c<16;c++) begin
            if (!voice_enable[c] || voice_restart[c]) begin
                timer[c] <= voice_reload[c]; sample_q[c] <= '0;
            end else if (tick) begin
                timer[c] <= timer[c]==16'hffff ? voice_reload[c] : timer[c]+1'b1;
                if (voice_advance[c]) sample_q[c] <= voice_next[c];
            end
        end
        for (int u=0;u<2;u++) begin
            if (!capture_enable[u]) begin
                capture_busy[u] <= 0; cap_count[u] <= 0; cap_timer[u] <= capture_reload[u];
            end else if (capture_restart[u]) begin
                capture_busy[u] <= 1; cap_count[u] <= 0; cap_timer[u] <= capture_reload[u];
            end else if (tick && capture_busy[u]) begin
                cap_timer[u] <= cap_timer[u]==16'hffff ? capture_reload[u] : cap_timer[u]+1'b1;
                if (cap_timer[u]==16'hffff) begin
                    capture_data[u] <= pcm16(mixed[u]);
                    capture_valid[u] <= 1;
                    cap_count[u] <= cap_count[u]+1'b1;
                    if (cap_count[u]+16'd1==capture_length[u]) capture_busy[u] <= 0;
                end
            end
        end
        if (rst) begin
            divider <= '0; capture_busy <= '0; capture_valid <= '0;
            for (int c=0;c<16;c++) begin timer[c] <= 0; sample_q[c] <= 0; end
            for (int u=0;u<2;u++) begin cap_timer[u] <= 0; cap_count[u] <= 0; capture_data[u] <= 0; end
        end
    end
endmodule
