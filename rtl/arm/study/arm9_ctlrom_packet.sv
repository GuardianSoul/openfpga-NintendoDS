// Defaultoff study helper. E token138bits, source-mandated D-only assert metadata43bits.
module arm9_ctlrom_packet #(parameter bit FAULT_TEMPLATE=0)(input logic clk,rst,hold_e,d_go,flush,input logic[31:0]c_ins,h_pc,c_bl2t,
 input logic[15:0]f_hw,rl_rem,
 input logic[4:0]c_cls,mode_in,
 input logic[3:0]rl_r,
 input logic[2:0]c_kind,
 input logic[1:0]ustep,
 input logic h_th,h_ab,h_v,qpa,c_bl2,take_fiq,take_irq,hivec,
output logic[300:0]d_packet,e_packet,output logic[22:0]seq);
 typedef struct packed{
  logic[31:0]ins;logic[15:0]hw;logic[31:0]pc,bltarget;logic[4:0]mode;
  logic[1:0]step;logic[3:0]listreg;logic[2:0]kind;logic[4:0]cls;
  logic valid,thumb,pcal,highvec;logic[2:0]inject;
 }raw_t;
 raw_t token;
 logic[34:0]ids;logic[42:0]donly,assert_metadata;
 logic[300:0]dshape,eshape;logic[23:0]droute,eroute;
logic[12:0]d0,e0;
logic[13:0]d1,e1;
logic[12:0]d2,e2;
logic[18:0]d3,e3;
logic[11:0]d4,e4;
logic[11:0]d5,e5;
ctlrom_address address(.c_ins,.h_pc,.c_bl2t,.f_hw,.rl_rem,.c_cls,.mode_in,.rl_r,.c_kind,.ustep,.h_th,.h_ab,.h_v,.qpa,.c_bl2,.take_fiq,.take_irq,.hivec,.ids,.donly,.seq);
arm9_ctlrom_planes #(.FAULT_TEMPLATE(FAULT_TEMPLATE)) banks(.clk,.rst,.hold_e,.ids,.d0,.e0,.d1,.e1,.d2,.e2,.d3,.e3,.d4,.e4,.d5,.e5);
always_comb begin dshape='0;eshape='0;
dshape[179+:1]=d0[0+:1];
eshape[179+:1]=e0[0+:1];
dshape[143+:3]=d0[1+:3];
eshape[143+:3]=e0[1+:3];
dshape[141+:1]=d0[4+:1];
eshape[141+:1]=e0[4+:1];
dshape[128+:5]=d0[5+:5];
eshape[128+:5]=e0[5+:5];
dshape[127+:1]=d0[10+:1];
eshape[127+:1]=e0[10+:1];
dshape[125+:2]=d0[11+:2];
eshape[125+:2]=e0[11+:2];
dshape[77+:2]=d1[0+:2];
eshape[77+:2]=e1[0+:2];
dshape[75+:2]=d1[2+:2];
eshape[75+:2]=e1[2+:2];
dshape[74+:1]=d1[4+:1];
eshape[74+:1]=e1[4+:1];
dshape[73+:1]=d1[5+:1];
eshape[73+:1]=e1[5+:1];
dshape[71+:2]=d1[6+:2];
eshape[71+:2]=e1[6+:2];
dshape[69+:2]=d1[8+:2];
eshape[69+:2]=e1[8+:2];
dshape[68+:1]=d1[10+:1];
eshape[68+:1]=e1[10+:1];
dshape[67+:1]=d1[11+:1];
eshape[67+:1]=e1[11+:1];
dshape[66+:1]=d1[12+:1];
eshape[66+:1]=e1[12+:1];
dshape[65+:1]=d1[13+:1];
eshape[65+:1]=e1[13+:1];
dshape[64+:1]=d2[0+:1];
eshape[64+:1]=e2[0+:1];
dshape[62+:2]=d2[1+:2];
eshape[62+:2]=e2[1+:2];
dshape[61+:1]=d2[3+:1];
eshape[61+:1]=e2[3+:1];
dshape[60+:1]=d2[4+:1];
eshape[60+:1]=e2[4+:1];
dshape[59+:1]=d2[5+:1];
eshape[59+:1]=e2[5+:1];
dshape[58+:1]=d2[6+:1];
eshape[58+:1]=e2[6+:1];
dshape[57+:1]=d2[7+:1];
eshape[57+:1]=e2[7+:1];
dshape[56+:1]=d2[8+:1];
eshape[56+:1]=e2[8+:1];
dshape[55+:1]=d2[9+:1];
eshape[55+:1]=e2[9+:1];
dshape[54+:1]=d2[10+:1];
eshape[54+:1]=e2[10+:1];
dshape[53+:1]=d2[11+:1];
eshape[53+:1]=e2[11+:1];
dshape[52+:1]=d2[12+:1];
eshape[52+:1]=e2[12+:1];
dshape[295+:1]=d3[0+:1];
eshape[295+:1]=e3[0+:1];
dshape[124+:1]=d3[1+:1];
eshape[124+:1]=e3[1+:1];
dshape[117+:2]=d3[2+:2];
eshape[117+:2]=e3[2+:2];
dshape[116+:1]=d3[4+:1];
eshape[116+:1]=e3[4+:1];
dshape[114+:2]=d3[5+:2];
eshape[114+:2]=e3[5+:2];
dshape[113+:1]=d3[7+:1];
eshape[113+:1]=e3[7+:1];
dshape[111+:2]=d3[8+:2];
eshape[111+:2]=e3[8+:2];
dshape[51+:1]=d3[10+:1];
eshape[51+:1]=e3[10+:1];
dshape[50+:1]=d3[11+:1];
eshape[50+:1]=e3[11+:1];
dshape[45+:1]=d3[12+:1];
eshape[45+:1]=e3[12+:1];
dshape[44+:1]=d3[13+:1];
eshape[44+:1]=e3[13+:1];
dshape[38+:1]=d3[14+:1];
eshape[38+:1]=e3[14+:1];
dshape[37+:1]=d3[15+:1];
eshape[37+:1]=e3[15+:1];
dshape[36+:1]=d3[16+:1];
eshape[36+:1]=e3[16+:1];
dshape[19+:1]=d3[17+:1];
eshape[19+:1]=e3[17+:1];
dshape[18+:1]=d3[18+:1];
eshape[18+:1]=e3[18+:1];
dshape[294]=donly[0];eshape[294]=assert_metadata[0];
dshape[193]=donly[1];eshape[193]=assert_metadata[1];
dshape[194]=donly[2];eshape[194]=assert_metadata[2];
dshape[195]=donly[3];eshape[195]=assert_metadata[3];
dshape[196]=donly[4];eshape[196]=assert_metadata[4];
dshape[197]=donly[5];eshape[197]=assert_metadata[5];
dshape[188]=donly[6];eshape[188]=assert_metadata[6];
dshape[189]=donly[7];eshape[189]=assert_metadata[7];
dshape[190]=donly[8];eshape[190]=assert_metadata[8];
dshape[191]=donly[9];eshape[191]=assert_metadata[9];
dshape[192]=donly[10];eshape[192]=assert_metadata[10];
dshape[183]=donly[11];eshape[183]=assert_metadata[11];
dshape[184]=donly[12];eshape[184]=assert_metadata[12];
dshape[185]=donly[13];eshape[185]=assert_metadata[13];
dshape[186]=donly[14];eshape[186]=assert_metadata[14];
dshape[187]=donly[15];eshape[187]=assert_metadata[15];
dshape[182]=donly[16];eshape[182]=assert_metadata[16];
dshape[181]=donly[17];eshape[181]=assert_metadata[17];
dshape[180]=donly[18];eshape[180]=assert_metadata[18];
dshape[178]=donly[19];eshape[178]=assert_metadata[19];
dshape[142]=donly[20];eshape[142]=assert_metadata[20];
dshape[133]=donly[21];eshape[133]=assert_metadata[21];
dshape[134]=donly[22];eshape[134]=assert_metadata[22];
dshape[135]=donly[23];eshape[135]=assert_metadata[23];
dshape[136]=donly[24];eshape[136]=assert_metadata[24];
dshape[137]=donly[25];eshape[137]=assert_metadata[25];
dshape[138]=donly[26];eshape[138]=assert_metadata[26];
dshape[139]=donly[27];eshape[139]=assert_metadata[27];
dshape[140]=donly[28];eshape[140]=assert_metadata[28];
dshape[17]=donly[29];eshape[17]=assert_metadata[29];
dshape[16]=donly[30];eshape[16]=assert_metadata[30];
dshape[12]=donly[31];eshape[12]=assert_metadata[31];
dshape[13]=donly[32];eshape[13]=assert_metadata[32];
dshape[14]=donly[33];eshape[14]=assert_metadata[33];
dshape[15]=donly[34];eshape[15]=assert_metadata[34];
dshape[8]=donly[35];eshape[8]=assert_metadata[35];
dshape[9]=donly[36];eshape[9]=assert_metadata[36];
dshape[10]=donly[37];eshape[10]=assert_metadata[37];
dshape[11]=donly[38];eshape[11]=assert_metadata[38];
dshape[4]=donly[39];eshape[4]=assert_metadata[39];
dshape[5]=donly[40];eshape[5]=assert_metadata[40];
dshape[6]=donly[41];eshape[6]=assert_metadata[41];
dshape[7]=donly[42];eshape[7]=assert_metadata[42];
dshape[300]=h_v;eshape[300]=token.valid;end
assign droute={d5,d4};assign eroute={e5,e4};
ctlrom_reconstruct d_reconstruct(.c_ins,.h_pc,.c_bl2t,.f_hw,.rl_rem,.c_cls,.mode_in,.rl_r,.c_kind,.ustep,.h_th,.h_ab,.h_v,.qpa,.c_bl2,.take_fiq,.take_irq,.hivec,.shape(dshape),.route(droute),.packet(d_packet));
ctlrom_reconstruct e_reconstruct(.c_ins(token.ins),.h_pc(token.pc),.c_bl2t(token.bltarget),.f_hw(token.hw),.rl_rem(16'd0),.c_cls(token.cls),.mode_in(token.mode),.rl_r(token.listreg),.c_kind(token.kind),.ustep(token.step),.h_th(token.thumb),.h_ab((token.inject==3'd1)),.h_v(token.valid),.qpa(token.pcal),.c_bl2(1'b0),.take_fiq((token.inject==3'd2)),.take_irq((token.inject==3'd3)),.hivec(token.highvec),.shape(eshape),.route(eroute),.packet(e_packet));
always_ff @(posedge clk)begin
 if(rst)begin token<='0;assert_metadata<=0;end
 else begin
  if(!hold_e)begin
   token.ins<=c_ins;token.hw<=f_hw;token.pc<=h_pc;token.bltarget<=c_bl2t;token.mode<=mode_in;
   token.step<=ustep;token.listreg<=rl_r;token.kind<=c_kind;token.cls<=c_cls;
   token.valid<=h_v&&d_go;token.thumb<=h_th;token.pcal<=qpa;token.highvec<=hivec;
   token.inject<=h_ab?3'd1:take_fiq?3'd2:take_irq?3'd3:3'd0;
   assert_metadata<=donly;
  end
  if(flush)token.valid<=0;
 end
end
`ifndef SYNTHESIS
 initial if($bits(raw_t)!=138)$fatal(1,"raw context token width changed");
`endif
endmodule
