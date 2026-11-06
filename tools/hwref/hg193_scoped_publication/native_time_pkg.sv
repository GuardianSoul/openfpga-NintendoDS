// Host fixture only. Integer simulator ticks; no DUT timing or clock changes.
package hg193_native_time;
 timeunit 1ps;
 timeprecision 1ps;
 localparam time ORIGINAL_TICKS_PS=64'd129210695256;
 function automatic time now_ps();
  return $time;
 endfunction
 function automatic bit exact(input time observed_ps);
  return observed_ps==ORIGINAL_TICKS_PS;
 endfunction
endpackage
