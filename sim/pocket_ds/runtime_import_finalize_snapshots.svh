// Versioned finalize input ABI:96 live words and64 independent frozen words.
// Canonical physical layout: live version0, frozen version1, frozen slots0..3.
// Caller holds clocks and drains finalize; no timing/reset state is changed.
// Define RUNTIME_FIN to the qualified versioned gpu3d_gxfin instance.
task automatic import_finalize_snapshots(input logic[31:0]live_words[0:5][0:15],input logic[31:0]frozen_words[0:3][0:15],input bit held);
 assert(held && !`RUNTIME_FIN.busy)else $fatal(1,"finalize snapshot publication not drained/frozen");
 `RUNTIME_FIN.slot_version=96'd0;
 for(int e=0;e<4;e++)begin `RUNTIME_FIN.snapshot_version[e]=16'hffff;`RUNTIME_FIN.snapshot_slot[e]=3'(e);end
 for(int slot=0;slot<6;slot++)`RUNTIME_FIN.g_snapshot_word[0].u_word.mem[slot]=live_words[slot][0];
 for(int e=0;e<4;e++)`RUNTIME_FIN.g_snapshot_word[0].u_word.mem[8+e]=frozen_words[e][0];
 for(int slot=0;slot<6;slot++)`RUNTIME_FIN.g_snapshot_word[1].u_word.mem[slot]=live_words[slot][1];
 for(int e=0;e<4;e++)`RUNTIME_FIN.g_snapshot_word[1].u_word.mem[8+e]=frozen_words[e][1];
 for(int slot=0;slot<6;slot++)`RUNTIME_FIN.g_snapshot_word[2].u_word.mem[slot]=live_words[slot][2];
 for(int e=0;e<4;e++)`RUNTIME_FIN.g_snapshot_word[2].u_word.mem[8+e]=frozen_words[e][2];
 for(int slot=0;slot<6;slot++)`RUNTIME_FIN.g_snapshot_word[3].u_word.mem[slot]=live_words[slot][3];
 for(int e=0;e<4;e++)`RUNTIME_FIN.g_snapshot_word[3].u_word.mem[8+e]=frozen_words[e][3];
 for(int slot=0;slot<6;slot++)`RUNTIME_FIN.g_snapshot_word[4].u_word.mem[slot]=live_words[slot][4];
 for(int e=0;e<4;e++)`RUNTIME_FIN.g_snapshot_word[4].u_word.mem[8+e]=frozen_words[e][4];
 for(int slot=0;slot<6;slot++)`RUNTIME_FIN.g_snapshot_word[5].u_word.mem[slot]=live_words[slot][5];
 for(int e=0;e<4;e++)`RUNTIME_FIN.g_snapshot_word[5].u_word.mem[8+e]=frozen_words[e][5];
 for(int slot=0;slot<6;slot++)`RUNTIME_FIN.g_snapshot_word[6].u_word.mem[slot]=live_words[slot][6];
 for(int e=0;e<4;e++)`RUNTIME_FIN.g_snapshot_word[6].u_word.mem[8+e]=frozen_words[e][6];
 for(int slot=0;slot<6;slot++)`RUNTIME_FIN.g_snapshot_word[7].u_word.mem[slot]=live_words[slot][7];
 for(int e=0;e<4;e++)`RUNTIME_FIN.g_snapshot_word[7].u_word.mem[8+e]=frozen_words[e][7];
 for(int slot=0;slot<6;slot++)`RUNTIME_FIN.g_snapshot_word[8].u_word.mem[slot]=live_words[slot][8];
 for(int e=0;e<4;e++)`RUNTIME_FIN.g_snapshot_word[8].u_word.mem[8+e]=frozen_words[e][8];
 for(int slot=0;slot<6;slot++)`RUNTIME_FIN.g_snapshot_word[9].u_word.mem[slot]=live_words[slot][9];
 for(int e=0;e<4;e++)`RUNTIME_FIN.g_snapshot_word[9].u_word.mem[8+e]=frozen_words[e][9];
 for(int slot=0;slot<6;slot++)`RUNTIME_FIN.g_snapshot_word[10].u_word.mem[slot]=live_words[slot][10];
 for(int e=0;e<4;e++)`RUNTIME_FIN.g_snapshot_word[10].u_word.mem[8+e]=frozen_words[e][10];
 for(int slot=0;slot<6;slot++)`RUNTIME_FIN.g_snapshot_word[11].u_word.mem[slot]=live_words[slot][11];
 for(int e=0;e<4;e++)`RUNTIME_FIN.g_snapshot_word[11].u_word.mem[8+e]=frozen_words[e][11];
 for(int slot=0;slot<6;slot++)`RUNTIME_FIN.g_snapshot_word[12].u_word.mem[slot]=live_words[slot][12];
 for(int e=0;e<4;e++)`RUNTIME_FIN.g_snapshot_word[12].u_word.mem[8+e]=frozen_words[e][12];
 for(int slot=0;slot<6;slot++)`RUNTIME_FIN.g_snapshot_word[13].u_word.mem[slot]=live_words[slot][13];
 for(int e=0;e<4;e++)`RUNTIME_FIN.g_snapshot_word[13].u_word.mem[8+e]=frozen_words[e][13];
 for(int slot=0;slot<6;slot++)`RUNTIME_FIN.g_snapshot_word[14].u_word.mem[slot]=live_words[slot][14];
 for(int e=0;e<4;e++)`RUNTIME_FIN.g_snapshot_word[14].u_word.mem[8+e]=frozen_words[e][14];
 for(int slot=0;slot<6;slot++)`RUNTIME_FIN.g_snapshot_word[15].u_word.mem[slot]=live_words[slot][15];
 for(int e=0;e<4;e++)`RUNTIME_FIN.g_snapshot_word[15].u_word.mem[8+e]=frozen_words[e][15];
`ifndef SYNTHESIS
 for(int slot=0;slot<6;slot++)for(int w=0;w<16;w++)`RUNTIME_FIN.check_slot[slot][w]=live_words[slot][w];
 for(int e=0;e<4;e++)for(int w=0;w<16;w++)`RUNTIME_FIN.check_snapshot[e][w]=frozen_words[e][w];
`endif
endtask
task automatic read_finalize_snapshots(output logic[31:0]live_words[0:5][0:15],output logic[31:0]frozen_words[0:3][0:15]);
 for(int e=0;e<4;e++)assert(`RUNTIME_FIN.snapshot_slot[e]<6)else $fatal(1,"finalize frozen slot is not representable");
 for(int slot=0;slot<6;slot++)live_words[slot][0]=`RUNTIME_FIN.g_snapshot_word[0].u_word.mem[8*int'(`RUNTIME_FIN.slot_version[16*slot+0])+slot];
 for(int e=0;e<4;e++)frozen_words[e][0]=`RUNTIME_FIN.g_snapshot_word[0].u_word.mem[8*int'(`RUNTIME_FIN.snapshot_version[e][0])+int'(`RUNTIME_FIN.snapshot_slot[e])];
 for(int slot=0;slot<6;slot++)live_words[slot][1]=`RUNTIME_FIN.g_snapshot_word[1].u_word.mem[8*int'(`RUNTIME_FIN.slot_version[16*slot+1])+slot];
 for(int e=0;e<4;e++)frozen_words[e][1]=`RUNTIME_FIN.g_snapshot_word[1].u_word.mem[8*int'(`RUNTIME_FIN.snapshot_version[e][1])+int'(`RUNTIME_FIN.snapshot_slot[e])];
 for(int slot=0;slot<6;slot++)live_words[slot][2]=`RUNTIME_FIN.g_snapshot_word[2].u_word.mem[8*int'(`RUNTIME_FIN.slot_version[16*slot+2])+slot];
 for(int e=0;e<4;e++)frozen_words[e][2]=`RUNTIME_FIN.g_snapshot_word[2].u_word.mem[8*int'(`RUNTIME_FIN.snapshot_version[e][2])+int'(`RUNTIME_FIN.snapshot_slot[e])];
 for(int slot=0;slot<6;slot++)live_words[slot][3]=`RUNTIME_FIN.g_snapshot_word[3].u_word.mem[8*int'(`RUNTIME_FIN.slot_version[16*slot+3])+slot];
 for(int e=0;e<4;e++)frozen_words[e][3]=`RUNTIME_FIN.g_snapshot_word[3].u_word.mem[8*int'(`RUNTIME_FIN.snapshot_version[e][3])+int'(`RUNTIME_FIN.snapshot_slot[e])];
 for(int slot=0;slot<6;slot++)live_words[slot][4]=`RUNTIME_FIN.g_snapshot_word[4].u_word.mem[8*int'(`RUNTIME_FIN.slot_version[16*slot+4])+slot];
 for(int e=0;e<4;e++)frozen_words[e][4]=`RUNTIME_FIN.g_snapshot_word[4].u_word.mem[8*int'(`RUNTIME_FIN.snapshot_version[e][4])+int'(`RUNTIME_FIN.snapshot_slot[e])];
 for(int slot=0;slot<6;slot++)live_words[slot][5]=`RUNTIME_FIN.g_snapshot_word[5].u_word.mem[8*int'(`RUNTIME_FIN.slot_version[16*slot+5])+slot];
 for(int e=0;e<4;e++)frozen_words[e][5]=`RUNTIME_FIN.g_snapshot_word[5].u_word.mem[8*int'(`RUNTIME_FIN.snapshot_version[e][5])+int'(`RUNTIME_FIN.snapshot_slot[e])];
 for(int slot=0;slot<6;slot++)live_words[slot][6]=`RUNTIME_FIN.g_snapshot_word[6].u_word.mem[8*int'(`RUNTIME_FIN.slot_version[16*slot+6])+slot];
 for(int e=0;e<4;e++)frozen_words[e][6]=`RUNTIME_FIN.g_snapshot_word[6].u_word.mem[8*int'(`RUNTIME_FIN.snapshot_version[e][6])+int'(`RUNTIME_FIN.snapshot_slot[e])];
 for(int slot=0;slot<6;slot++)live_words[slot][7]=`RUNTIME_FIN.g_snapshot_word[7].u_word.mem[8*int'(`RUNTIME_FIN.slot_version[16*slot+7])+slot];
 for(int e=0;e<4;e++)frozen_words[e][7]=`RUNTIME_FIN.g_snapshot_word[7].u_word.mem[8*int'(`RUNTIME_FIN.snapshot_version[e][7])+int'(`RUNTIME_FIN.snapshot_slot[e])];
 for(int slot=0;slot<6;slot++)live_words[slot][8]=`RUNTIME_FIN.g_snapshot_word[8].u_word.mem[8*int'(`RUNTIME_FIN.slot_version[16*slot+8])+slot];
 for(int e=0;e<4;e++)frozen_words[e][8]=`RUNTIME_FIN.g_snapshot_word[8].u_word.mem[8*int'(`RUNTIME_FIN.snapshot_version[e][8])+int'(`RUNTIME_FIN.snapshot_slot[e])];
 for(int slot=0;slot<6;slot++)live_words[slot][9]=`RUNTIME_FIN.g_snapshot_word[9].u_word.mem[8*int'(`RUNTIME_FIN.slot_version[16*slot+9])+slot];
 for(int e=0;e<4;e++)frozen_words[e][9]=`RUNTIME_FIN.g_snapshot_word[9].u_word.mem[8*int'(`RUNTIME_FIN.snapshot_version[e][9])+int'(`RUNTIME_FIN.snapshot_slot[e])];
 for(int slot=0;slot<6;slot++)live_words[slot][10]=`RUNTIME_FIN.g_snapshot_word[10].u_word.mem[8*int'(`RUNTIME_FIN.slot_version[16*slot+10])+slot];
 for(int e=0;e<4;e++)frozen_words[e][10]=`RUNTIME_FIN.g_snapshot_word[10].u_word.mem[8*int'(`RUNTIME_FIN.snapshot_version[e][10])+int'(`RUNTIME_FIN.snapshot_slot[e])];
 for(int slot=0;slot<6;slot++)live_words[slot][11]=`RUNTIME_FIN.g_snapshot_word[11].u_word.mem[8*int'(`RUNTIME_FIN.slot_version[16*slot+11])+slot];
 for(int e=0;e<4;e++)frozen_words[e][11]=`RUNTIME_FIN.g_snapshot_word[11].u_word.mem[8*int'(`RUNTIME_FIN.snapshot_version[e][11])+int'(`RUNTIME_FIN.snapshot_slot[e])];
 for(int slot=0;slot<6;slot++)live_words[slot][12]=`RUNTIME_FIN.g_snapshot_word[12].u_word.mem[8*int'(`RUNTIME_FIN.slot_version[16*slot+12])+slot];
 for(int e=0;e<4;e++)frozen_words[e][12]=`RUNTIME_FIN.g_snapshot_word[12].u_word.mem[8*int'(`RUNTIME_FIN.snapshot_version[e][12])+int'(`RUNTIME_FIN.snapshot_slot[e])];
 for(int slot=0;slot<6;slot++)live_words[slot][13]=`RUNTIME_FIN.g_snapshot_word[13].u_word.mem[8*int'(`RUNTIME_FIN.slot_version[16*slot+13])+slot];
 for(int e=0;e<4;e++)frozen_words[e][13]=`RUNTIME_FIN.g_snapshot_word[13].u_word.mem[8*int'(`RUNTIME_FIN.snapshot_version[e][13])+int'(`RUNTIME_FIN.snapshot_slot[e])];
 for(int slot=0;slot<6;slot++)live_words[slot][14]=`RUNTIME_FIN.g_snapshot_word[14].u_word.mem[8*int'(`RUNTIME_FIN.slot_version[16*slot+14])+slot];
 for(int e=0;e<4;e++)frozen_words[e][14]=`RUNTIME_FIN.g_snapshot_word[14].u_word.mem[8*int'(`RUNTIME_FIN.snapshot_version[e][14])+int'(`RUNTIME_FIN.snapshot_slot[e])];
 for(int slot=0;slot<6;slot++)live_words[slot][15]=`RUNTIME_FIN.g_snapshot_word[15].u_word.mem[8*int'(`RUNTIME_FIN.slot_version[16*slot+15])+slot];
 for(int e=0;e<4;e++)frozen_words[e][15]=`RUNTIME_FIN.g_snapshot_word[15].u_word.mem[8*int'(`RUNTIME_FIN.snapshot_version[e][15])+int'(`RUNTIME_FIN.snapshot_slot[e])];
endtask
task automatic verify_finalize_snapshots(input logic[31:0]live_words[0:5][0:15],input logic[31:0]frozen_words[0:3][0:15]);
 logic[31:0]actual_live[0:5][0:15],actual_frozen[0:3][0:15];
 read_finalize_snapshots(actual_live,actual_frozen);
 for(int slot=0;slot<6;slot++)for(int w=0;w<16;w++)assert(actual_live[slot][w]===live_words[slot][w])else $fatal(1,"finalize live restore mismatch slot%0d word%0d",slot,w);
 for(int e=0;e<4;e++)for(int w=0;w<16;w++)assert(actual_frozen[e][w]===frozen_words[e][w])else $fatal(1,"finalize frozen restore mismatch entry%0d word%0d",e,w);
endtask
