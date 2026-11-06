module tb_meta_cdc;
 logic mc=0,sc=0,rst=1,mr=0,md,sr,sd=0;
 logic [77:0] mp=0,sp,held;
 logic [31:0] mq,sq;
 int seen=0,delay=0;
 logic pending=0;
 always #3 mc=~mc;
 always #5 sc=~sc;
 cdc_req #(.PW(78),.QW(32)) u(.m_clk(mc),.m_rst(rst),.m_req(mr),.m_p(mp),.m_done(md),.m_q(mq),.s_clk(sc),.s_rst(rst),.s_req(sr),.s_p(sp),.s_done(sd),.s_q(sq));
 always @(negedge sc) begin
  sd=0;
  if (rst) begin pending=0;delay=0;end
  else if (sr) begin
   if (!pending) begin held=sp;pending=1;delay=seen%6;end
   if (sp!==held) $fatal(1,"CDC descriptor/payload unstable");
   if (delay==0) begin sq=sp[31:0] ^ {24'd0,sp[77:70]};sd=1;seen=seen+1;end
   else delay=delay-1;
  end else pending=0;
 end
 initial begin
  repeat(8) @(negedge mc);rst=0;
  for(int n=0;n<32;n++) begin
   @(negedge mc);mp={7'(n*7),n[0],n[1],n[2],n[3:0],32'h02410000+32'(n*4),32'h13240000+32'(n)};mr=1;
   do @(negedge mc); while(!md);
   if(mq!==(mp[31:0] ^ {24'd0,mp[77:70]})) $fatal(1,"CDC marker/data mismatch");
   mr=0;repeat(3) @(negedge mc);
  end
  if(seen!=32) $fatal(1,"duplicate/missing ACK");
  $display("CDC_META_PASS 32 asynchronous78bit packets");$finish;
 end
 initial begin #100000;$fatal(1,"CDC timeout");end
endmodule
