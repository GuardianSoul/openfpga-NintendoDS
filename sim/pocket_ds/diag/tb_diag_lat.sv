// nds_diag_lat: random requests, up to 4 in flight, answered in order after random latencies; every bin
// against a model of the four modes. diag.sh runs it.
`timescale 1ns/1ps
module tb_diag_lat;
    logic clk = 0, rst = 1;
    always #5 clk = !clk;
    logic start = 0, stop = 0;
    wire [3:0] v;
    wire [15:0] bn;
    genvar g;
    for (g = 0; g < 4; g++) begin : g_m
        nds_diag_lat #(.MODE(g), .STEP(4)) u (.clk, .rst, .start, .stop, .v(v[g]), .bin(bn[g*4 +: 4]));
    end
    function automatic [3:0] model(input int mode, input int l);
        case (mode)
            0: begin model = 0; for (int i = 0; i < 15; i++) if (l >= (1 << i)) model = i + 1; end
            1: model = l >= 60 ? 15 : l / 4;
            2: model = l < 16 ? 0 : l >= 44 ? 15 : (l - 16) / 2 + 1;
            default: model = l < 48 ? l / 4 : l < 64 ? 12 : l < 128 ? 13 : l < 256 ? 14 : 15;
        endcase
    endfunction
    int q [$];                 // the stop clock of each request in flight
    int now = 0, errors = 0, n = 0;
    int st [$];                // their start clocks
    int exp_l [$];
    always @(posedge clk) if (!rst && v[0]) begin
        int l;
        l = exp_l.pop_front();
        for (int m = 0; m < 4; m++) if (bn[m*4 +: 4] !== model(m, l)) begin
            errors++; if (errors < 10) $display("ERROR mode %0d latency %0d: bin %0d, expected %0d", m, l, bn[m*4 +: 4], model(m, l));
        end
        n++;
    end
    initial begin
        int seed, t;
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        void'($urandom(seed));
        repeat (5) @(posedge clk); rst <= 0;
        t = 0;
        for (int c = 0; c < 200000; c++) begin
            // a new request now and then (up to 4 in flight); each is answered after a random latency, in order
            start <= 0; stop <= 0;
            if (st.size() < 4 && $urandom % 8 == 0) begin
                int l, s;
                l = ($urandom % 4 == 0) ? $urandom % 400 : $urandom % 70;
                s = c + 1 + l;                                  // its stop clock
                if (q.size() && s <= q[$]) s = q[$] + 1;        // in order, one stop a clock
                start <= 1; st.push_back(c); q.push_back(s);
            end
            if (q.size() && q[0] == c) begin stop <= 1; exp_l.push_back(c - st[0]); void'(q.pop_front()); void'(st.pop_front()); end
            @(posedge clk);
        end
        repeat (5) @(posedge clk);
        $display("diag_lat: %0d latencies, %0d errors", n, errors);
        if (errors == 0 && n > 1000) $display("PASS"); else $display("FAIL");
        $finish;
    end
endmodule
