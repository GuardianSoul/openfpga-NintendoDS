// Two fixed physical context rows, one stage-service write per FAST edge.
// Async MLAB/logic: old odd row is consumed while a different even row writes.
// Sync M10K/MLAB/logic: prefetch next odd owner (current even owner). A current
// write to that same row bypasses the RAM's unspecified read-during-write value.
// The stored read and live bypass are both real state, not free RAM/FF credit.
module arm_context_bank #(
 parameter int WIDTH=32,
 parameter STYLE="MLAB",
 parameter bit SYNC=0,
 parameter bit FAULT_OWNER=0
)(
 input logic clk,we,even_owner,odd_owner,
 input logic[WIDTH-1:0] wdata,
 output logic[WIDTH-1:0] rdata
);
 (* ramstyle=STYLE *) logic[WIDTH-1:0] backing[0:1];
 always_ff @(posedge clk) if(we) backing[even_owner]<=wdata;
 generate if(SYNC)begin:prefetch
  logic[WIDTH-1:0] held_q,live_q;
  logic live_sel;
  wire next_owner=even_owner ^ FAULT_OWNER;
  always_ff @(posedge clk)begin
   held_q<=backing[next_owner];
   if(we)live_q<=wdata;
   live_sel<=we && even_owner==next_owner;
  end
  assign rdata=live_sel?live_q:held_q;
 end else begin:asynchronous
  assign rdata=backing[odd_owner ^ FAULT_OWNER];
 end endgenerate
`ifndef SYNTHESIS
`ifndef ALTERA_RESERVED_QIS
 initial if(!SYNC && STYLE=="M10K")$fatal(1,"context bank: M10K requires synchronous prefetch");
`endif
`endif
endmodule
