// Owned worker layout1: registered config/body banks, live loop bytes in FF.
// Full mirrors come from import_sound_storage; no clock advances during deposit.
task automatic import_sound_owned_shadows(input logic [31:0] config_words [0:127],input logic [159:0] runtime_rows [0:31],input logic [31:0] meta [0:55]);
    int entry,slot_now;
    assert(`RUNTIME_SOUND.OWNED_RUNTIME && `RUNTIME_SOUND.OWNED_SHADOW_LAYOUT==1 &&
           !`RUNTIME_SOUND.ce && !`RUNTIME_SOUND.rst && `RUNTIME_SOUND.st==`RUNTIME_SOUND.S_IDLE &&
           `RUNTIME_SOUND.fs==`RUNTIME_SOUND.F_IDLE && `RUNTIME_SOUND.q_cnt==0 &&
           `RUNTIME_SOUND.event_count==0 && !`RUNTIME_SOUND.event_head_valid &&
           !`RUNTIME_SOUND.reg_req && !`RUNTIME_SOUND.win && !`RUNTIME_SOUND.lsv_q &&
           !`RUNTIME_SOUND.selpass && !`RUNTIME_SOUND.event_output &&
           !(|(`RUNTIME_SOUND.event_mask & ~`RUNTIME_SOUND.WORKER_MASK)))
        else $fatal(1,"sound owned banks import requires layout1 stopped quiescent worker");
    slot_now=int'(`RUNTIME_SOUND.ent[3:2]);
    for(int slot=0;slot<4;slot++)begin
        entry=slot*4+`RUNTIME_SOUND.WORKER_ID;
        `RUNTIME_SOUND.g_owned_config.g_word[0].g_byte[0].u_bank.mem[slot]=config_words[0*32+entry][0+:8];
        `RUNTIME_SOUND.g_owned_config.g_word[0].g_byte[1].u_bank.mem[slot]=config_words[0*32+entry][8+:8];
        `RUNTIME_SOUND.g_owned_config.g_word[0].g_byte[2].u_bank.mem[slot]=config_words[0*32+entry][16+:8];
        `RUNTIME_SOUND.g_owned_config.g_word[0].g_byte[3].u_bank.mem[slot]=config_words[0*32+entry][24+:8];
        `RUNTIME_SOUND.g_owned_config.g_word[1].g_byte[0].u_bank.mem[slot]=config_words[1*32+entry][0+:8];
        `RUNTIME_SOUND.g_owned_config.g_word[1].g_byte[1].u_bank.mem[slot]=config_words[1*32+entry][8+:8];
        `RUNTIME_SOUND.g_owned_config.g_word[1].g_byte[2].u_bank.mem[slot]=config_words[1*32+entry][16+:8];
        `RUNTIME_SOUND.g_owned_config.g_word[1].g_byte[3].u_bank.mem[slot]=config_words[1*32+entry][24+:8];
        `RUNTIME_SOUND.g_owned_config.g_word[2].g_byte[0].u_bank.mem[slot]=config_words[2*32+entry][0+:8];
        `RUNTIME_SOUND.g_owned_config.g_word[2].g_byte[1].u_bank.mem[slot]=config_words[2*32+entry][8+:8];
        `RUNTIME_SOUND.g_owned_config.g_word[2].g_byte[2].u_bank.mem[slot]=config_words[2*32+entry][16+:8];
        `RUNTIME_SOUND.g_owned_config.g_word[2].g_byte[3].u_bank.mem[slot]=config_words[2*32+entry][24+:8];
        `RUNTIME_SOUND.g_owned_config.g_word[3].g_byte[0].u_bank.mem[slot]=config_words[3*32+entry][0+:8];
        `RUNTIME_SOUND.g_owned_config.g_word[3].g_byte[1].u_bank.mem[slot]=config_words[3*32+entry][8+:8];
        `RUNTIME_SOUND.g_owned_config.g_word[3].g_byte[2].u_bank.mem[slot]=config_words[3*32+entry][16+:8];
        `RUNTIME_SOUND.g_owned_config.g_word[3].g_byte[3].u_bank.mem[slot]=config_words[3*32+entry][24+:8];
        `RUNTIME_SOUND.g_owned_runtime.g_byte[0].g_body.u_bank.mem[slot]=runtime_rows[entry][0+:8];
        `RUNTIME_SOUND.g_owned_runtime.g_byte[1].g_body.u_bank.mem[slot]=runtime_rows[entry][8+:8];
        `RUNTIME_SOUND.g_owned_runtime.g_byte[2].g_body.u_bank.mem[slot]=runtime_rows[entry][16+:8];
        `RUNTIME_SOUND.g_owned_runtime.g_byte[3].g_body.u_bank.mem[slot]=runtime_rows[entry][24+:8];
        `RUNTIME_SOUND.g_owned_runtime.g_byte[5].g_body.u_bank.mem[slot]=runtime_rows[entry][40+:8];
        `RUNTIME_SOUND.g_owned_runtime.g_byte[6].g_body.u_bank.mem[slot]=runtime_rows[entry][48+:8];
        `RUNTIME_SOUND.g_owned_runtime.g_byte[7].g_body.u_bank.mem[slot]=runtime_rows[entry][56+:8];
        `RUNTIME_SOUND.g_owned_runtime.g_byte[8].g_body.u_bank.mem[slot]=runtime_rows[entry][64+:8];
        `RUNTIME_SOUND.g_owned_runtime.g_byte[9].g_body.u_bank.mem[slot]=runtime_rows[entry][72+:8];
        `RUNTIME_SOUND.g_owned_runtime.g_byte[10].g_body.u_bank.mem[slot]=runtime_rows[entry][80+:8];
        `RUNTIME_SOUND.g_owned_runtime.g_byte[11].g_body.u_bank.mem[slot]=runtime_rows[entry][88+:8];
        `RUNTIME_SOUND.g_owned_runtime.g_byte[12].g_body.u_bank.mem[slot]=runtime_rows[entry][96+:8];
        `RUNTIME_SOUND.g_owned_runtime.g_byte[13].g_body.u_bank.mem[slot]=runtime_rows[entry][104+:8];
        `RUNTIME_SOUND.g_owned_runtime.g_byte[14].g_body.u_bank.mem[slot]=runtime_rows[entry][112+:8];
        `RUNTIME_SOUND.g_owned_runtime.g_byte[15].g_body.u_bank.mem[slot]=runtime_rows[entry][120+:8];
        `RUNTIME_SOUND.g_owned_runtime.g_byte[16].g_body.u_bank.mem[slot]=runtime_rows[entry][128+:8];
        `RUNTIME_SOUND.g_owned_runtime.g_byte[17].g_body.u_bank.mem[slot]=runtime_rows[entry][136+:8];
        `RUNTIME_SOUND.g_owned_runtime.loop_state[slot]={runtime_rows[entry][159:144],runtime_rows[entry][39:32]};
    end
    entry=slot_now*4+`RUNTIME_SOUND.WORKER_ID;
    `RUNTIME_SOUND.g_owned_config.g_word[0].g_byte[0].u_bank.q=config_words[0*32+entry][0+:8];
    `RUNTIME_SOUND.g_owned_config.g_word[0].g_byte[1].u_bank.q=config_words[0*32+entry][8+:8];
    `RUNTIME_SOUND.g_owned_config.g_word[0].g_byte[2].u_bank.q=config_words[0*32+entry][16+:8];
    `RUNTIME_SOUND.g_owned_config.g_word[0].g_byte[3].u_bank.q=config_words[0*32+entry][24+:8];
    `RUNTIME_SOUND.g_owned_config.g_word[1].g_byte[0].u_bank.q=config_words[1*32+entry][0+:8];
    `RUNTIME_SOUND.g_owned_config.g_word[1].g_byte[1].u_bank.q=config_words[1*32+entry][8+:8];
    `RUNTIME_SOUND.g_owned_config.g_word[1].g_byte[2].u_bank.q=config_words[1*32+entry][16+:8];
    `RUNTIME_SOUND.g_owned_config.g_word[1].g_byte[3].u_bank.q=config_words[1*32+entry][24+:8];
    `RUNTIME_SOUND.g_owned_config.g_word[2].g_byte[0].u_bank.q=config_words[2*32+entry][0+:8];
    `RUNTIME_SOUND.g_owned_config.g_word[2].g_byte[1].u_bank.q=config_words[2*32+entry][8+:8];
    `RUNTIME_SOUND.g_owned_config.g_word[2].g_byte[2].u_bank.q=config_words[2*32+entry][16+:8];
    `RUNTIME_SOUND.g_owned_config.g_word[2].g_byte[3].u_bank.q=config_words[2*32+entry][24+:8];
    `RUNTIME_SOUND.g_owned_config.g_word[3].g_byte[0].u_bank.q=config_words[3*32+entry][0+:8];
    `RUNTIME_SOUND.g_owned_config.g_word[3].g_byte[1].u_bank.q=config_words[3*32+entry][8+:8];
    `RUNTIME_SOUND.g_owned_config.g_word[3].g_byte[2].u_bank.q=config_words[3*32+entry][16+:8];
    `RUNTIME_SOUND.g_owned_config.g_word[3].g_byte[3].u_bank.q=config_words[3*32+entry][24+:8];
    `RUNTIME_SOUND.g_owned_runtime.g_byte[0].g_body.u_bank.q=runtime_rows[entry][0+:8];
    `RUNTIME_SOUND.g_owned_runtime.g_byte[1].g_body.u_bank.q=runtime_rows[entry][8+:8];
    `RUNTIME_SOUND.g_owned_runtime.g_byte[2].g_body.u_bank.q=runtime_rows[entry][16+:8];
    `RUNTIME_SOUND.g_owned_runtime.g_byte[3].g_body.u_bank.q=runtime_rows[entry][24+:8];
    `RUNTIME_SOUND.g_owned_runtime.g_byte[5].g_body.u_bank.q=runtime_rows[entry][40+:8];
    `RUNTIME_SOUND.g_owned_runtime.g_byte[6].g_body.u_bank.q=runtime_rows[entry][48+:8];
    `RUNTIME_SOUND.g_owned_runtime.g_byte[7].g_body.u_bank.q=runtime_rows[entry][56+:8];
    `RUNTIME_SOUND.g_owned_runtime.g_byte[8].g_body.u_bank.q=runtime_rows[entry][64+:8];
    `RUNTIME_SOUND.g_owned_runtime.g_byte[9].g_body.u_bank.q=runtime_rows[entry][72+:8];
    `RUNTIME_SOUND.g_owned_runtime.g_byte[10].g_body.u_bank.q=runtime_rows[entry][80+:8];
    `RUNTIME_SOUND.g_owned_runtime.g_byte[11].g_body.u_bank.q=runtime_rows[entry][88+:8];
    `RUNTIME_SOUND.g_owned_runtime.g_byte[12].g_body.u_bank.q=runtime_rows[entry][96+:8];
    `RUNTIME_SOUND.g_owned_runtime.g_byte[13].g_body.u_bank.q=runtime_rows[entry][104+:8];
    `RUNTIME_SOUND.g_owned_runtime.g_byte[14].g_body.u_bank.q=runtime_rows[entry][112+:8];
    `RUNTIME_SOUND.g_owned_runtime.g_byte[15].g_body.u_bank.q=runtime_rows[entry][120+:8];
    `RUNTIME_SOUND.g_owned_runtime.g_byte[16].g_body.u_bank.q=runtime_rows[entry][128+:8];
    `RUNTIME_SOUND.g_owned_runtime.g_byte[17].g_body.u_bank.q=runtime_rows[entry][136+:8];
    `RUNTIME_SOUND.g_owned_runtime.sample1=`RUNTIME_SOUND.WORKER_ID==1 ? meta[6][15:0] : 16'd0;
    `RUNTIME_SOUND.g_owned_runtime.sample3=`RUNTIME_SOUND.WORKER_ID==3 ? meta[7][15:0] : 16'd0;
`ifndef SYNTHESIS
    `RUNTIME_SOUND.g_owned_config.read_valid_q=!`RUNTIME_SOUND.ent[4] && `RUNTIME_SOUND.ent[1:0]==2'(`RUNTIME_SOUND.WORKER_ID);
    `RUNTIME_SOUND.g_owned_config.read_slot_q=2'(slot_now);
    `RUNTIME_SOUND.g_owned_runtime.read_valid_q=!`RUNTIME_SOUND.ent[4] && `RUNTIME_SOUND.ent[1:0]==2'(`RUNTIME_SOUND.WORKER_ID);
    `RUNTIME_SOUND.g_owned_runtime.read_slot_q=2'(slot_now);
    `RUNTIME_SOUND.g_owned_config.g_word[0].g_byte[0].collision_q=0;
    `RUNTIME_SOUND.g_owned_config.g_word[0].g_byte[1].collision_q=0;
    `RUNTIME_SOUND.g_owned_config.g_word[0].g_byte[2].collision_q=0;
    `RUNTIME_SOUND.g_owned_config.g_word[0].g_byte[3].collision_q=0;
    `RUNTIME_SOUND.g_owned_config.g_word[1].g_byte[0].collision_q=0;
    `RUNTIME_SOUND.g_owned_config.g_word[1].g_byte[1].collision_q=0;
    `RUNTIME_SOUND.g_owned_config.g_word[1].g_byte[2].collision_q=0;
    `RUNTIME_SOUND.g_owned_config.g_word[1].g_byte[3].collision_q=0;
    `RUNTIME_SOUND.g_owned_config.g_word[2].g_byte[0].collision_q=0;
    `RUNTIME_SOUND.g_owned_config.g_word[2].g_byte[1].collision_q=0;
    `RUNTIME_SOUND.g_owned_config.g_word[2].g_byte[2].collision_q=0;
    `RUNTIME_SOUND.g_owned_config.g_word[2].g_byte[3].collision_q=0;
    `RUNTIME_SOUND.g_owned_config.g_word[3].g_byte[0].collision_q=0;
    `RUNTIME_SOUND.g_owned_config.g_word[3].g_byte[1].collision_q=0;
    `RUNTIME_SOUND.g_owned_config.g_word[3].g_byte[2].collision_q=0;
    `RUNTIME_SOUND.g_owned_config.g_word[3].g_byte[3].collision_q=0;
    `RUNTIME_SOUND.g_owned_runtime.g_byte[0].g_body.collision_q=0;
    `RUNTIME_SOUND.g_owned_runtime.g_byte[1].g_body.collision_q=0;
    `RUNTIME_SOUND.g_owned_runtime.g_byte[2].g_body.collision_q=0;
    `RUNTIME_SOUND.g_owned_runtime.g_byte[3].g_body.collision_q=0;
    `RUNTIME_SOUND.g_owned_runtime.g_byte[5].g_body.collision_q=0;
    `RUNTIME_SOUND.g_owned_runtime.g_byte[6].g_body.collision_q=0;
    `RUNTIME_SOUND.g_owned_runtime.g_byte[7].g_body.collision_q=0;
    `RUNTIME_SOUND.g_owned_runtime.g_byte[8].g_body.collision_q=0;
    `RUNTIME_SOUND.g_owned_runtime.g_byte[9].g_body.collision_q=0;
    `RUNTIME_SOUND.g_owned_runtime.g_byte[10].g_body.collision_q=0;
    `RUNTIME_SOUND.g_owned_runtime.g_byte[11].g_body.collision_q=0;
    `RUNTIME_SOUND.g_owned_runtime.g_byte[12].g_body.collision_q=0;
    `RUNTIME_SOUND.g_owned_runtime.g_byte[13].g_body.collision_q=0;
    `RUNTIME_SOUND.g_owned_runtime.g_byte[14].g_body.collision_q=0;
    `RUNTIME_SOUND.g_owned_runtime.g_byte[15].g_body.collision_q=0;
    `RUNTIME_SOUND.g_owned_runtime.g_byte[16].g_body.collision_q=0;
    `RUNTIME_SOUND.g_owned_runtime.g_byte[17].g_body.collision_q=0;
`endif
endtask
