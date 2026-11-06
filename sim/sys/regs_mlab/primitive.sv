// Bounded native async MLAB oracle; collision output is deliberately poisoned.
module altdpram #(
 parameter ram_block_type="",intended_device_family="",width=20,widthad=5,numwords=32,
 parameter indata_reg="",wraddress_reg="",wrcontrol_reg="",rdaddress_reg="",
 parameter rdcontrol_reg="",outdata_reg="",read_during_write_mode_mixed_ports="",lpm_type="",lpm_file="",indata_aclr="",wraddress_aclr="",wrcontrol_aclr="",rdaddress_aclr="",rdcontrol_aclr="",outdata_aclr=""
)(input logic inclock,inclocken,wren,rden,outclock,outclocken,aclr,sclr,
 input logic wraddressstall,rdaddressstall,byteena,
 input logic[widthad-1:0]wraddress,rdaddress,input logic[width-1:0]data,
 output wire[width-1:0]q);
 logic[width-1:0]mem_data[0:numwords-1];logic poison=0;
 initial for(integer a=0;a<numwords;a++)mem_data[a]=0;
 initial assert(ram_block_type=="MLAB"&&intended_device_family=="Cyclone V"&&
 widthad==5&&numwords==32&&width==8&&indata_reg=="INCLOCK"&&
 wraddress_reg=="INCLOCK"&&wrcontrol_reg=="INCLOCK"&&
 rdaddress_reg=="UNREGISTERED"&&rdcontrol_reg=="UNREGISTERED"&&
 outdata_reg=="UNREGISTERED"&&read_during_write_mode_mixed_ports=="DONT_CARE");
 always @(posedge inclock)begin
  assert(inclocken&&rden&&outclocken&&!aclr&&!sclr&&!wraddressstall&&!rdaddressstall&&byteena);
  poison=wren&&wraddress==rdaddress;if(wren)mem_data[wraddress]<=data;
 end
 always @(negedge inclock)poison=0;
 assign q=poison?~mem_data[rdaddress]:mem_data[rdaddress];
endmodule
