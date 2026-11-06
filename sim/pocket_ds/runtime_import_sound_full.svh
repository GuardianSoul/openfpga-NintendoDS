// The full generic shadows. Current compact MULTI_PARENT must use
// runtime_import_sound_parent.svh; a stale full-bank deposit must fail closed.
task automatic import_sound_full_shadows(input logic [31:0] config_words [0:127],input logic [159:0] runtime_rows [0:31]);
    assert(!`RUNTIME_SOUND.MULTI_PARENT)else $fatal(1,"full-shadow helper cannot restore compact parent");
    for(int e=0;e<32;e++)begin
        for(int w=0;w<4;w++)`RUNTIME_SOUND.fast_config[w][e]=config_words[w*32+e];
        `RUNTIME_SOUND.fast_runtime[e]=runtime_rows[e];
    end
endtask
