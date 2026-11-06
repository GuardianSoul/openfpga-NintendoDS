// Qualified packed physical record RAM deposit; valid active records only.
// Define RUNTIME_GX_RECORDS to nds_g3d_record_ram PACK1. Caller stops clocks.
task automatic import_gx_records(input logic[15:0]record_addresses[],input logic[31:0]record_words[],input bit held);
 assert(held&&`RUNTIME_GX_RECORDS.left==0&&!`RUNTIME_GX_RECORDS.p_req&&`RUNTIME_GX_RECORDS.PACK)else $fatal(1,"record publication has pending old return");
 assert($size(record_addresses)<=16384&&$size(record_words)==4*$size(record_addresses))else $fatal(1,"GX record import image lengths differ");
 for(int i=0;i<$size(record_addresses);i++)begin
  assert(record_addresses[i]<16384)else $fatal(1,"GX record index truncation");
  `RUNTIME_GX_RECORDS.g_pack.g_lane[0].g_full.u_lane.mem[record_addresses[i]]=record_words[4*i];
  `RUNTIME_GX_RECORDS.g_pack.g_lane[1].g_full.u_lane.mem[record_addresses[i]]=record_words[4*i+1];
  `RUNTIME_GX_RECORDS.g_pack.g_lane[3].g_full.u_lane.mem[record_addresses[i]]=record_words[4*i+3];
  case(record_addresses[i][12:11])
   0:`RUNTIME_GX_RECORDS.g_pack.g_lane[0].u_tail.mem[{record_addresses[i][13],record_addresses[i][10:0]}]={record_words[4*i+2][31:19],record_words[4*i+2][11:0]};
   1:`RUNTIME_GX_RECORDS.g_pack.g_lane[1].u_tail.mem[{record_addresses[i][13],record_addresses[i][10:0]}]=record_words[4*i+2][19:0];
   2:`RUNTIME_GX_RECORDS.g_pack.g_lane[2].u_tail.mem[{record_addresses[i][13],record_addresses[i][10:0]}]=record_words[4*i+2][19:0];
   3:`RUNTIME_GX_RECORDS.g_pack.g_lane[3].u_tail.mem[{record_addresses[i][13],record_addresses[i][10:0]}]=record_words[4*i+2][19:0];
  endcase
 end
endtask
