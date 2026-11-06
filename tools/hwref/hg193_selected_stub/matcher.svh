// Simulation-only content check. No ownership/readiness guard is replaced.
package hg193_selected_stub;
 localparam int WORDS=137,TRAMP_WORD=107;
 localparam logic[31:0] STUB_BASE=32'h02309000;
 localparam logic[31:0] TAIL_RUN=32'h023091b0,TAIL_HALT=32'h023091e8;
 function automatic bit content_match(input logic[31:0] initial_words[WORDS],
  input logic[31:0] live_words[WORDS],input logic selection_known,halted);
  logic[31:0] expected;
  if(selection_known!==1'b1 || !((halted===1'b0)||(halted===1'b1)))return 0;
  for(int i=0;i<WORDS;i++)begin
   expected=i==TRAMP_WORD ? (halted?TAIL_HALT:TAIL_RUN) : initial_words[i];
   if(live_words[i]!==expected)return 0;
  end
  return 1;
 endfunction
endpackage
