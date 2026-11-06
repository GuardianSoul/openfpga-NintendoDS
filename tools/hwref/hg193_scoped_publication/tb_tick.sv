module tb_tick;
 timeunit 1ns;
 timeprecision 1ps;
 wire clk_sys,clk_2x;
 time candidate,observed;
 bit previous_seen=0,current_seen=0;
 nds_pll_ds pll(.refclk(1'b0),.rst(1'b0),.clk_sys,.clk_2x);
 initial begin
  assert(hg193_native_time::now_ps()==0);
  assert(hg193_native_time::exact(64'd129210695256));
  assert(!hg193_native_time::exact(64'd129210695255) &&
         !hg193_native_time::exact(64'd129210695257));
 end
 // Reuse the actual SYS-fall -> existing FAST-fall alignment. There is no
 // added phase, clock change, readiness wait or game-state publication here.
 always @(negedge clk_sys)begin
  if(clk_2x)@(negedge clk_2x);
  observed=hg193_native_time::now_ps();
  if(observed==hg193_native_time::ORIGINAL_TICKS_PS-64'd14919)begin
   assert(!hg193_native_time::exact(observed));previous_seen=1;
   $display("TICK_PREVIOUS_HOOK_REJECTED ticks_ps=%0d",observed);
  end
  if(observed==hg193_native_time::ORIGINAL_TICKS_PS)begin
   assert(previous_seen && $time==64'd129210695 && $realtime!=129210695.0);
   candidate=$test$plusargs("legacy_unit") ? $time : hg193_native_time::now_ps();
   $display("TICK_SOURCE console_ps=%0t exact_ps=%0d candidate=%0d realtime_ns=%.3f",$time,hg193_native_time::now_ps(),candidate,$realtime);
   assert(hg193_native_time::exact(candidate))else $fatal(1,"LIVE_WRONG_TIME_UNIT_REJECTED");
   assert(!hg193_native_time::exact(observed-1) && !hg193_native_time::exact(observed+1));
   current_seen=1;
  end
  if(observed==hg193_native_time::ORIGINAL_TICKS_PS+64'd14919)begin
   assert(current_seen && !hg193_native_time::exact(observed));
   $display("TICK_NEXT_HOOK_REJECTED ticks_ps=%0d",observed);
   $display("INTEGER_PS_TICK_COMPONENT_PASS original_PLL_actual_hook_exact_plusminus1ps_adjacent_hooks");
   $finish;
  end
 end
 initial begin #129211000;$fatal(1,"integer tick hook timeout");end
endmodule
