module a7_fullmul_tb;
 logic[32:0]a,b;
 wire signed[65:0]native_p,fallback_p,bad_p;
 logic signed[65:0]oracle;
 logic[63:0]acc,expected,observed;
 logic[63:0]rng=64'h761023caffe837ab;
 bit mutant;
 arm_mul_full33_native n(.a,.b,.product(native_p));
 arm_mul_full33_fallback f(.a,.b,.product(fallback_p));
 arm_mul_full33_bad m(.a,.b,.product(bad_p));
 function automatic logic[63:0]rand64();
  rng^=rng<<13;rng^=rng>>7;rng^=rng<<17;return rng;
 endfunction
 task automatic check(input logic[32:0]x,y,input logic[63:0]z);
  a=x;b=y;acc=z;#1;
  oracle=$signed(a)*$signed(b);expected=oracle[63:0]+acc;
  observed=native_p[63:0]+acc;
  if(native_p!==oracle||fallback_p!==oracle||observed!==expected)
   $fatal(1,"A7_FULL66_ORACLE a%h b%h native%h fallback%h expected%h",a,b,native_p,fallback_p,oracle);
  if(mutant&&bad_p!==oracle)
   $fatal(1,"A7_NATIVE_BY_FULL66_FAULT a%h b%h bad%h expected%h",a,b,bad_p,oracle);
 endtask
 initial begin
  mutant=$test$plusargs("mutant");
  for(int i=0;i<33;i++)for(int j=0;j<33;j++)begin
   check(33'd1<<i,33'd1<<j,64'hffffffffffffffff);
   check(~(33'd1<<i),~(33'd1<<j),64'h8000000000000001);
  end
  for(int i=0;i<200000;i++)begin
   logic[63:0]x,y,z;x=rand64();y=rand64();z=rand64();
   case(i%4)
    0:check({1'b0,x[31:0]},{1'b0,y[31:0]},z);
    1:check({x[31],x[31:0]},{y[31],y[31:0]},z);
    2:check({{17{x[15]}},x[15:0]},{{17{y[15]}},y[15:0]},z);
    default:check(x[32:0],y[32:0],z);
   endcase
  end
  if(mutant)$fatal(1,"actual mutant escaped");
  $display("A7_FULL66_PASS 202178 native/fallback/oracle/64bit-accumulator checks");$finish;
 end
endmodule
