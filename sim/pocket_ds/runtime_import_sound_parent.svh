// Layout 2 parent shadows. Include inside a testbench scope with RUNTIME_SOUND.
// Caller restores full storage separately; no clocks may advance during import.
task automatic import_sound_parent_shadows(input logic [31:0] config_words[0:127], input logic [159:0] runtime_rows[0:31]);
    int entry,slot_now;
    assert(`RUNTIME_SOUND.MULTI_PARENT && `RUNTIME_SOUND.PARENT_SHADOW_LAYOUT==2 &&
           !`RUNTIME_SOUND.ce && !`RUNTIME_SOUND.rst && `RUNTIME_SOUND.st==`RUNTIME_SOUND.S_IDLE &&
           `RUNTIME_SOUND.workers_idle && `RUNTIME_SOUND.event_count==0 && !`RUNTIME_SOUND.event_head_valid &&
           !`RUNTIME_SOUND.reg_req && !`RUNTIME_SOUND.event_write_queued &&
           !`RUNTIME_SOUND.event_write_due && `RUNTIME_SOUND.event_outputs_pending==0 && `RUNTIME_SOUND.q_cnt==0 &&
           `RUNTIME_SOUND.fs==`RUNTIME_SOUND.F_IDLE && !`RUNTIME_SOUND.win && !`RUNTIME_SOUND.lsv_q &&
           !`RUNTIME_SOUND.selpass &&
           `RUNTIME_SOUND.g_workers.response_count==0 && !`RUNTIME_SOUND.g_workers.hold_valid)
        else $fatal(1,"sound parent banks import requires layout2 stopped quiescent parent");
    slot_now=int'(`RUNTIME_SOUND.parent_read_slot);
    for(int slot=0;slot<4;slot++)begin
        entry=slot<2 ? 1+2*slot : 14+slot;
        `RUNTIME_SOUND.g_parent_config.g_word[0].g_byte[0].u_bank.mem[slot]=config_words[0*32+entry][0+:8];
        `RUNTIME_SOUND.g_parent_config.g_word[0].g_byte[1].u_bank.mem[slot]=config_words[0*32+entry][8+:8];
        `RUNTIME_SOUND.g_parent_config.g_word[0].g_byte[2].u_bank.mem[slot]=config_words[0*32+entry][16+:8];
        `RUNTIME_SOUND.g_parent_config.g_word[0].g_byte[3].u_bank.mem[slot]=config_words[0*32+entry][24+:8];
        `RUNTIME_SOUND.g_parent_config.g_word[1].g_byte[0].u_bank.mem[slot]=config_words[1*32+entry][0+:8];
        `RUNTIME_SOUND.g_parent_config.g_word[1].g_byte[1].u_bank.mem[slot]=config_words[1*32+entry][8+:8];
        `RUNTIME_SOUND.g_parent_config.g_word[1].g_byte[2].u_bank.mem[slot]=config_words[1*32+entry][16+:8];
        `RUNTIME_SOUND.g_parent_config.g_word[1].g_byte[3].u_bank.mem[slot]=config_words[1*32+entry][24+:8];
        `RUNTIME_SOUND.g_parent_config.g_word[2].g_byte[0].u_bank.mem[slot]=config_words[2*32+entry][0+:8];
        `RUNTIME_SOUND.g_parent_config.g_word[2].g_byte[1].u_bank.mem[slot]=config_words[2*32+entry][8+:8];
        `RUNTIME_SOUND.g_parent_config.g_word[2].g_byte[2].u_bank.mem[slot]=config_words[2*32+entry][16+:8];
        `RUNTIME_SOUND.g_parent_config.g_word[2].g_byte[3].u_bank.mem[slot]=config_words[2*32+entry][24+:8];
        `RUNTIME_SOUND.g_parent_config.g_word[3].g_byte[0].u_bank.mem[slot]=config_words[3*32+entry][0+:8];
        `RUNTIME_SOUND.g_parent_config.g_word[3].g_byte[1].u_bank.mem[slot]=config_words[3*32+entry][8+:8];
        `RUNTIME_SOUND.g_parent_config.g_word[3].g_byte[2].u_bank.mem[slot]=config_words[3*32+entry][16+:8];
        `RUNTIME_SOUND.g_parent_config.g_word[3].g_byte[3].u_bank.mem[slot]=config_words[3*32+entry][24+:8];
        `RUNTIME_SOUND.g_parent_runtime.g_byte[0].u_bank.mem[slot]=runtime_rows[entry][0+:8];
        `RUNTIME_SOUND.g_parent_runtime.g_byte[1].u_bank.mem[slot]=runtime_rows[entry][8+:8];
        `RUNTIME_SOUND.g_parent_runtime.g_byte[2].u_bank.mem[slot]=runtime_rows[entry][16+:8];
        `RUNTIME_SOUND.g_parent_runtime.g_byte[3].u_bank.mem[slot]=runtime_rows[entry][24+:8];
        `RUNTIME_SOUND.g_parent_runtime.g_byte[4].u_bank.mem[slot]=runtime_rows[entry][32+:8];
        `RUNTIME_SOUND.g_parent_runtime.g_byte[5].u_bank.mem[slot]=runtime_rows[entry][40+:8];
        `RUNTIME_SOUND.g_parent_runtime.g_byte[6].u_bank.mem[slot]=runtime_rows[entry][48+:8];
        `RUNTIME_SOUND.g_parent_runtime.g_byte[7].u_bank.mem[slot]=runtime_rows[entry][56+:8];
        `RUNTIME_SOUND.g_parent_runtime.g_byte[8].u_bank.mem[slot]=runtime_rows[entry][64+:8];
        `RUNTIME_SOUND.g_parent_runtime.g_byte[9].u_bank.mem[slot]=runtime_rows[entry][72+:8];
        `RUNTIME_SOUND.g_parent_runtime.g_byte[10].u_bank.mem[slot]=runtime_rows[entry][80+:8];
        `RUNTIME_SOUND.g_parent_runtime.g_byte[11].u_bank.mem[slot]=runtime_rows[entry][88+:8];
        `RUNTIME_SOUND.g_parent_runtime.g_byte[12].u_bank.mem[slot]=runtime_rows[entry][96+:8];
        `RUNTIME_SOUND.g_parent_runtime.g_byte[13].u_bank.mem[slot]=runtime_rows[entry][104+:8];
        `RUNTIME_SOUND.g_parent_runtime.g_byte[14].u_bank.mem[slot]=runtime_rows[entry][112+:8];
        `RUNTIME_SOUND.g_parent_runtime.g_byte[15].u_bank.mem[slot]=runtime_rows[entry][120+:8];
        `RUNTIME_SOUND.g_parent_runtime.g_byte[16].u_bank.mem[slot]=runtime_rows[entry][128+:8];
        `RUNTIME_SOUND.g_parent_runtime.g_byte[17].u_bank.mem[slot]=runtime_rows[entry][136+:8];
        `RUNTIME_SOUND.g_parent_runtime.g_byte[18].u_bank.mem[slot]=runtime_rows[entry][144+:8];
        `RUNTIME_SOUND.g_parent_runtime.g_byte[19].u_bank.mem[slot]=runtime_rows[entry][152+:8];
    end
    entry=slot_now<2 ? 1+2*slot_now : 14+slot_now;
    `RUNTIME_SOUND.g_parent_config.g_word[0].g_byte[0].u_bank.q=config_words[0*32+entry][0+:8];
    `RUNTIME_SOUND.g_parent_config.g_word[0].g_byte[1].u_bank.q=config_words[0*32+entry][8+:8];
    `RUNTIME_SOUND.g_parent_config.g_word[0].g_byte[2].u_bank.q=config_words[0*32+entry][16+:8];
    `RUNTIME_SOUND.g_parent_config.g_word[0].g_byte[3].u_bank.q=config_words[0*32+entry][24+:8];
    `RUNTIME_SOUND.g_parent_config.g_word[1].g_byte[0].u_bank.q=config_words[1*32+entry][0+:8];
    `RUNTIME_SOUND.g_parent_config.g_word[1].g_byte[1].u_bank.q=config_words[1*32+entry][8+:8];
    `RUNTIME_SOUND.g_parent_config.g_word[1].g_byte[2].u_bank.q=config_words[1*32+entry][16+:8];
    `RUNTIME_SOUND.g_parent_config.g_word[1].g_byte[3].u_bank.q=config_words[1*32+entry][24+:8];
    `RUNTIME_SOUND.g_parent_config.g_word[2].g_byte[0].u_bank.q=config_words[2*32+entry][0+:8];
    `RUNTIME_SOUND.g_parent_config.g_word[2].g_byte[1].u_bank.q=config_words[2*32+entry][8+:8];
    `RUNTIME_SOUND.g_parent_config.g_word[2].g_byte[2].u_bank.q=config_words[2*32+entry][16+:8];
    `RUNTIME_SOUND.g_parent_config.g_word[2].g_byte[3].u_bank.q=config_words[2*32+entry][24+:8];
    `RUNTIME_SOUND.g_parent_config.g_word[3].g_byte[0].u_bank.q=config_words[3*32+entry][0+:8];
    `RUNTIME_SOUND.g_parent_config.g_word[3].g_byte[1].u_bank.q=config_words[3*32+entry][8+:8];
    `RUNTIME_SOUND.g_parent_config.g_word[3].g_byte[2].u_bank.q=config_words[3*32+entry][16+:8];
    `RUNTIME_SOUND.g_parent_config.g_word[3].g_byte[3].u_bank.q=config_words[3*32+entry][24+:8];
    `RUNTIME_SOUND.g_parent_runtime.g_byte[0].u_bank.q=runtime_rows[entry][0+:8];
    `RUNTIME_SOUND.g_parent_runtime.g_byte[1].u_bank.q=runtime_rows[entry][8+:8];
    `RUNTIME_SOUND.g_parent_runtime.g_byte[2].u_bank.q=runtime_rows[entry][16+:8];
    `RUNTIME_SOUND.g_parent_runtime.g_byte[3].u_bank.q=runtime_rows[entry][24+:8];
    `RUNTIME_SOUND.g_parent_runtime.g_byte[4].u_bank.q=runtime_rows[entry][32+:8];
    `RUNTIME_SOUND.g_parent_runtime.g_byte[5].u_bank.q=runtime_rows[entry][40+:8];
    `RUNTIME_SOUND.g_parent_runtime.g_byte[6].u_bank.q=runtime_rows[entry][48+:8];
    `RUNTIME_SOUND.g_parent_runtime.g_byte[7].u_bank.q=runtime_rows[entry][56+:8];
    `RUNTIME_SOUND.g_parent_runtime.g_byte[8].u_bank.q=runtime_rows[entry][64+:8];
    `RUNTIME_SOUND.g_parent_runtime.g_byte[9].u_bank.q=runtime_rows[entry][72+:8];
    `RUNTIME_SOUND.g_parent_runtime.g_byte[10].u_bank.q=runtime_rows[entry][80+:8];
    `RUNTIME_SOUND.g_parent_runtime.g_byte[11].u_bank.q=runtime_rows[entry][88+:8];
    `RUNTIME_SOUND.g_parent_runtime.g_byte[12].u_bank.q=runtime_rows[entry][96+:8];
    `RUNTIME_SOUND.g_parent_runtime.g_byte[13].u_bank.q=runtime_rows[entry][104+:8];
    `RUNTIME_SOUND.g_parent_runtime.g_byte[14].u_bank.q=runtime_rows[entry][112+:8];
    `RUNTIME_SOUND.g_parent_runtime.g_byte[15].u_bank.q=runtime_rows[entry][120+:8];
    `RUNTIME_SOUND.g_parent_runtime.g_byte[16].u_bank.q=runtime_rows[entry][128+:8];
    `RUNTIME_SOUND.g_parent_runtime.g_byte[17].u_bank.q=runtime_rows[entry][136+:8];
    `RUNTIME_SOUND.g_parent_runtime.g_byte[18].u_bank.q=runtime_rows[entry][144+:8];
    `RUNTIME_SOUND.g_parent_runtime.g_byte[19].u_bank.q=runtime_rows[entry][152+:8];
    `RUNTIME_SOUND.g_parent_runtime.sample1=runtime_rows[1][31:16];
    `RUNTIME_SOUND.g_parent_runtime.sample3=runtime_rows[3][31:16];
`ifndef SYNTHESIS
    `RUNTIME_SOUND.g_parent_config.g_word[0].collision_q=0;
    `RUNTIME_SOUND.g_parent_config.g_word[1].collision_q=0;
    `RUNTIME_SOUND.g_parent_config.g_word[2].collision_q=0;
    `RUNTIME_SOUND.g_parent_config.g_word[3].collision_q=0;
    `RUNTIME_SOUND.g_parent_config.read_valid_q=`RUNTIME_SOUND.parent_read_valid;
    `RUNTIME_SOUND.g_parent_config.read_slot_q=`RUNTIME_SOUND.parent_read_slot;
    `RUNTIME_SOUND.g_parent_runtime.read_valid_q=`RUNTIME_SOUND.parent_read_valid;
    `RUNTIME_SOUND.g_parent_runtime.read_slot_q=`RUNTIME_SOUND.parent_read_slot;
    `RUNTIME_SOUND.g_parent_runtime.collision_q=0;
`endif
endtask
