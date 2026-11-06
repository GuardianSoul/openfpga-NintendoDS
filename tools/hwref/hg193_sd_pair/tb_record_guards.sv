// STAGED ONLY: execute after coordinator assigns a component slot.
// Compile with the bound nds_g3d_sd_records.sv and gpu3d_ram.sv, --assert.
// +packets=<prepared>/sd-packets.hex +case=valid|wrong-record|wrong-tag.
// Negative runs must fail at the production SD_RECORD_STALE_OR_CORRUPT_RETURN
// guard, with no p_rdone. A timeout is not a successful negative control.
`timescale 1ns/1ps
module tb_record_guards;
 logic clk=0,rst=1,sp_ready=1;
 always #5 clk=~clk;
 logic p_req=0,p_we=0,p_ack,p_rvalid,p_rdone;
 logic[22:2]p_addr=0;
 logic[31:0]p_wdata=0,p_rdata;
 logic sw_req,sr_req,fault;
 logic[23:0]sw_addr,sr_addr;
 logic[31:0]sw_data,sr_data=0;
 logic sr_valid=0;
 nds_g3d_sd_records dut(.clk,.rst,.sp_ready,.p_req,.p_we,.p_addr,.p_wdata,
  .p_ack,.p_rvalid,.p_rdone,.p_rdata,.sw_req,.sw_addr,.sw_data,
  .sw_ack(1'b1),.sw_drained(1'b1),.sr_req,.sr_addr,.sr_ack(1'b1),.sr_valid,.sr_data,.fault);
 logic[31:0]packets[0:131071];
 string path,kind="valid";
 int base,beat;
 bit response=0;
 int valid_words=0,done_count=0;
 int selected_key;
 always @(posedge clk)begin
  sr_valid<=0;
  if(sr_req)begin
   assert(!response)else $fatal(1,"test response overlap");
   base=int'(sr_addr)-'h1a0000;beat=0;response=1;
   if(kind=="wrong-record")base=8; // Complete record1 returned to record0.
  end else if(response)begin
   sr_valid<=1;
   sr_data<=packets[base+beat] ^ ((kind=="wrong-tag" && beat==4)?32'd4:32'd0);
   if(beat==7)response=0;
   else beat++;
  end
  if(p_rvalid)begin
   if(kind=="valid")assert(p_rdata===packets[8*selected_key+valid_words])
    else $fatal(1,"actual RTL payload translation mismatch");
   valid_words++;
  end
  if(p_rdone)begin
   assert(kind=="valid" && valid_words==4)else $fatal(1,"invalid record was published");
   done_count++;
  end
 end
 task automatic read_record(input int key);
  @(negedge clk);selected_key=key;valid_words=0;
  p_addr={2'b10,1'(key>>13),3'd0,13'(key),2'd0};p_req=1;
  do @(posedge clk);while(!p_ack);
  @(negedge clk);p_req=0;
  wait(p_rdone);@(posedge clk);@(negedge clk);
 endtask
 initial begin
  assert($value$plusargs("packets=%s",path))else $fatal(1,"missing prepared packet image");
  if($value$plusargs("case=%s",kind))begin end
  assert(kind=="valid" || kind=="wrong-record" || kind=="wrong-tag")else $fatal(1,"bad case");
  $readmemh(path,packets);
  repeat(3)@(negedge clk);rst=0;
  repeat(8)@(negedge clk);
  read_record(0);
  if(kind!="valid")$fatal(1,"production guard failed to reject corrupt record");
  read_record(621);read_record('h800);read_record('h1993);read_record('h2000);
  assert(done_count==5 && !fault)else $fatal(1,"actual canonical read qualification incomplete");
  $display("HG193_ACTUAL_RECORD_GUARD_VALID_PASS records5");$finish;
 end
 initial begin #20000;$fatal(1,"component timeout; not an accepted rejection");end
endmodule
