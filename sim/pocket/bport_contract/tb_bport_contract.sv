`timescale 1ns/1ps
module tb_bport_contract;
    reg clk_bus = 0, clk_mem = 0, reset = 1;
    always #5 clk_bus = !clk_bus;
    always #2 clk_mem = !clk_mem;
    reg c_valid = 0, c_write = 0, c_quad = 0;
    reg [23:0] c_addr = 0;
    reg [31:0] c_wdata = 0;
    reg [3:0] c_be = 0;
    wire c_ready;
    nds_sdram_bport #(.SHARED(1)) dut (
        .clk_bus, .clk_mem, .reset, .c_valid, .c_write, .c_quad,
        .c_addr, .c_wdata, .c_be, .c_ready, .r_valid(), .r_data(),
        .m_valid(), .m_we(), .m_addr(), .m_n(), .m_wdata(), .m_be(),
        .m_take(1'b0), .w_valid(1'b0), .w_data(32'd0));

    // No forced internals or copied assertion: actual bport captures the request,
    // waits for take, and its real diagnostic samples exactly one mutated edge.
    task automatic run_case(input integer id, kind, old_be, new_be, bitno);
        begin
            reset = 1;
            repeat (2) @(posedge clk_bus);
            @(negedge clk_bus);
            $display("CASE_BEGIN %0d %0d %0d %0d %0d", id, kind, old_be, new_be, bitno);
            reset = 0; c_valid = 1; c_write = kind >= 8; c_quad = 0;
            c_addr = 24'h04006d; c_wdata = 32'h12345678;
            c_be = kind == 15 ? 4'h1 : old_be[3:0];
            @(negedge clk_bus); // the preceding positive edge captured b_*
            case (kind)
                1, 9: c_be = new_be[3:0];
                2: c_wdata = ~c_wdata;
                3: begin c_be = ~c_be; c_wdata = ~c_wdata; end
                4, 12: c_addr = c_addr ^ 24'd1;
                5, 14: c_quad = 1;
                6, 11: c_valid = 0;
                7: c_write = 1;
                10: c_wdata = c_wdata ^ (32'h1 << bitno);
                13: c_write = 0;
                15: c_wdata = c_wdata ^ 32'hff000000; // retain conservative full write-data check
                default: begin end
            endcase
            @(negedge clk_bus); // exactly one diagnostic sampling edge elapsed
            reset = 1; c_valid = 0;
            $display("CASE_END %0d", id);
        end
    endtask
    integer id = 0;
    initial begin
        for (integer kind = 0; kind <= 15; kind = kind + 1)
            if (kind != 1 && kind != 9 && kind != 10) begin
                run_case(id, kind, 0, 0, 0); id = id + 1;
            end
        for (integer a = 0; a < 16; a = a + 1)
            for (integer b = 0; b < 16; b = b + 1) begin
                run_case(id, 1, a, b, 0); id = id + 1;
                run_case(id, 9, a, b, 0); id = id + 1;
            end
        for (integer bitno = 0; bitno < 32; bitno = bitno + 1) begin
            run_case(id, 10, 15, 15, bitno); id = id + 1;
        end
        $display("TB_DONE %0d", id);
        $finish;
    end
    initial begin #100000; $fatal(1, "testbench timeout"); end
endmodule
