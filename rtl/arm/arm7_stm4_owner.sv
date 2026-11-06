// Passive metadata owner leaf; public P7/fabric integration is separate.
// Inputs must be the ACTUAL P7 admission, CPU acceptance and old write ACK.
// Does not drive any queue, memory request, ACK, CPU run or service control.
module arm7_stm4_owner import arm_pkg::*; #(
  parameter bit ENABLE = 0
) (
  input logic clk,
  input logic rst_cpu, rst_port,
  input a7_stm4_meta_t request_meta,
  input logic write_admit, cpu_accept, physical_ack,
  output a7_stm4_meta_t answer_owner, posted_owner,
  output a7_stm4_meta_t accepted_owner, physical_done
);
  generate if (ENABLE) begin : g_on
    always_ff @(posedge clk) begin
      if (rst_cpu || rst_port) answer_owner <= '0;
      else begin
        if (cpu_accept) answer_owner <= '0;
        if (write_admit) answer_owner <= request_meta;
      end
      // A CPU reset/redirect cannot erase a committed posted write.
      if (rst_port) posted_owner <= '0;
      else begin
        if (physical_ack) posted_owner <= '0;
        if (write_admit) posted_owner <= request_meta;
      end
    end
    // Pre-edge owners: same-edge replacement exposes OLD completion and
    // captures NEW ownership only at the edge, independently for each slot.
    assign accepted_owner = !rst_cpu && !rst_port && cpu_accept ? answer_owner : '0;
    assign physical_done = !rst_port && physical_ack ? posted_owner : '0;
  end else begin : g_off
    assign answer_owner = '0;
    assign posted_owner = '0;
    assign accepted_owner = '0;
    assign physical_done = '0;
  end endgenerate
endmodule
