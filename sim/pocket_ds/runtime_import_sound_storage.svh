// Simulation-only semantic storage deposit. This is the last-batch state;
// physical timer/event epoch replay and atomic CPU/display publication are
// separate required steps. Define RUNTIME_SOUND to an actual sound engine.
task automatic import_sound_storage(
    input logic [31:0] config_words [0:127],
    input logic [159:0] runtime_rows [0:31],
    input logic [31:0] fifo_words [0:127],
    input logic [1:0] fifo_tags [0:127],
    input logic [31:0] capture_words [0:7],
    input logic [31:0] meta [0:55]
);
    assert(!`RUNTIME_SOUND.ce && `RUNTIME_SOUND.st==`RUNTIME_SOUND.S_IDLE &&
           `RUNTIME_SOUND.fs==`RUNTIME_SOUND.F_IDLE && `RUNTIME_SOUND.q_cnt==0 &&
           `RUNTIME_SOUND.event_count==0) else $fatal(1,"sound import storage not quiescent");
    for(int a=0;a<128;a++) begin
        `RUNTIME_SOUND.u_cpu.mem[a]=config_words[a];
        `RUNTIME_SOUND.u_fifo.mem[a]=fifo_words[a];
        `RUNTIME_SOUND.u_tag.mem[a]=fifo_tags[a];
    end
    for(int a=0;a<32;a++)`RUNTIME_SOUND.u_run.mem[a]=runtime_rows[a];
    for(int a=0;a<8;a++)`RUNTIME_SOUND.u_cb.mem[a]=capture_words[a];
    `RUNTIME_SOUND.soundcnt=meta[0][15:0]; `RUNTIME_SOUND.bias=meta[1][15:0];
    `RUNTIME_SOUND.capcnt0=meta[2][7:0]; `RUNTIME_SOUND.capcnt1=meta[3][7:0];
    `RUNTIME_SOUND.busy=meta[4][15:0]; `RUNTIME_SOUND.keyon=meta[5][15:0];
    `RUNTIME_SOUND.cap_start=0; // already-running captures do not restart
    // The optional compact contribution layout keeps one row per owned
    // channel group. Keep compatibility with the qualified old16-row bank.
    if($size(`RUNTIME_SOUND.event_left)==4)begin
        for(int slot=0;slot<4;slot++)begin
            `RUNTIME_SOUND.event_left[slot]=28'(meta[8+4*slot+`RUNTIME_SOUND.WORKER_ID]);
            `RUNTIME_SOUND.event_right[slot]=28'(meta[24+4*slot+`RUNTIME_SOUND.WORKER_ID]);
        end
    end else for(int ch=0;ch<16;ch++)begin
        `RUNTIME_SOUND.event_left[ch]=`RUNTIME_SOUND.WORKER_ID<0 || ch%4==`RUNTIME_SOUND.WORKER_ID ? 28'(meta[8+ch]) : 28'd0;
        `RUNTIME_SOUND.event_right[ch]=`RUNTIME_SOUND.WORKER_ID<0 || ch%4==`RUNTIME_SOUND.WORKER_ID ? 28'(meta[24+ch]) : 28'd0;
    end
    `RUNTIME_SOUND.postvol[0]=`RUNTIME_SOUND.WORKER_ID<0 || `RUNTIME_SOUND.WORKER_ID==0 ? 28'(meta[40]) : 28'd0;
    `RUNTIME_SOUND.postvol[1]=`RUNTIME_SOUND.WORKER_ID<0 || `RUNTIME_SOUND.WORKER_ID==2 ? 28'(meta[42]) : 28'd0;
endtask
