// Simulation-only physical timer deposit at a paused sound transaction.
// Initial counters and the divider must share the caller's observed epoch.
// This does not advance decoders, normalize CPU timers or publish the core.
// Define RUNTIME_SOUND to the actual parent sound engine before inclusion.
task automatic import_sound_phase(
    input logic [15:0] timer_values [0:17],
    input logic [15:0] reload_values [0:17],
    input int divider_value
);
    assert(!`RUNTIME_SOUND.ce && `RUNTIME_SOUND.st==`RUNTIME_SOUND.S_IDLE &&
           `RUNTIME_SOUND.workers_idle && `RUNTIME_SOUND.event_count==0)
        else $fatal(1,"sound phase import not quiescent");
    assert(divider_value>=0 && divider_value<`RUNTIME_SOUND.TIMER_DIV)
        else $fatal(1,"sound phase divider out of range");
    for(int n=0;n<18;n++)begin
        `RUNTIME_SOUND.g_event_timers.bank.timer[n]=timer_values[n];
        `RUNTIME_SOUND.g_event_timers.bank.reload[n]=reload_values[n];
    end
    `RUNTIME_SOUND.g_event_timers.bank.divider=$bits(`RUNTIME_SOUND.g_event_timers.bank.divider)'(divider_value);
endtask
