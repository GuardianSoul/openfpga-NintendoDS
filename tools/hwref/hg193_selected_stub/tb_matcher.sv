`include "matcher.svh"
module tb_matcher;
 import hg193_selected_stub::*;
 logic[31:0] original[WORDS],replayed[WORDS],v[WORDS];
 string initial_path,replayed_path;
 integer checks=0;
 initial begin
  assert($value$plusargs("initial=%s",initial_path));
  assert($value$plusargs("replayed=%s",replayed_path));
  $readmemh(initial_path,original);$readmemh(replayed_path,replayed);
  assert(original[TRAMP_WORD]===0 && replayed[TRAMP_WORD]===TAIL_RUN);
  assert(content_match(original,replayed,1'b1,1'b0));checks++;
  assert(!content_match(original,original,1'b1,1'b0));checks++;
  assert(!content_match(original,replayed,1'b0,1'b0));checks++;
  assert(!content_match(original,replayed,1'b1,1'b1));checks++;
  v=replayed;v[TRAMP_WORD]=32'h000094a0;assert(!content_match(original,v,1'b1,1'b0));checks++;
  for(int i=0;i<WORDS;i++)for(int b=0;b<32;b++)begin
   v=replayed;v[i][b]=!v[i][b];assert(!content_match(original,v,1'b1,1'b0))
    else $fatal(1,"SELECTED_STUB_PAYLOAD_FAULT_MISSED word%0d bit%0d",i,b);
   checks++;
  end
  $display("SELECTED_STUB_MATCHER_PASS checks%0d payload_mutants%0d exact_selected_tail136immutable",checks,WORDS*32);
  $finish;
 end
endmodule
