// Elaboration-only stand-in for APF's vendor DDR I/O primitive. The real
// mf_ddio_bidir_12 wrapper, APF bridge/pad controllers and core are compiled.
// This check does not execute or qualify pad timing/electrical behavior.
module altddio_bidir #(
  parameter extend_oe_disable="OFF",implement_input_in_lcell="OFF",
  intended_device_family="Cyclone V",invert_output="OFF",lpm_hint="UNUSED",
  lpm_type="altddio_bidir",oe_reg="UNREGISTERED",power_up_high="OFF",
  parameter integer width=12
)(input logic [width-1:0]datain_h,datain_l,
  input logic inclock,oe,outclock,aclr,aset,inclocken,outclocken,sclr,sset,
  inout wire [width-1:0]padio,
  output wire [width-1:0]dataout_h,dataout_l,combout,dqsundelayedout,
  output wire oe_out);
  assign padio=oe?datain_h:{width{1'bz}};
  assign dataout_h=padio;assign dataout_l=padio;assign combout=padio;
  assign dqsundelayedout='0;assign oe_out=oe;
endmodule
