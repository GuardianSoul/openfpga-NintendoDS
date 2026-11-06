// Timer-only front end for the existing serialized decoder. Each nonempty
// physical timer edge becomes one ordered mask; backend latency cannot merge it.
module sound_event_timers #(parameter integer TIMER_DIV=2) (
    input logic clk,ce,rst,run,sync_tick,
    input logic [17:0] enabled,restart,
    input logic config_we,
    input logic [4:0] config_addr,
    input logic [1:0] config_be,
    input logic [15:0] config_data,
    output logic [17:0] due
);
    localparam integer CW=TIMER_DIV>1?$clog2(TIMER_DIV):1;
    logic [CW-1:0] divider;
    logic [15:0] reload [18], timer [18];
    wire timer_tick=sync_tick || divider==CW'(TIMER_DIV-1);
    always_comb begin
        due='0;
        for(int n=0;n<18;n++)
            due[n]=run && timer_tick && enabled[n] && !restart[n] && timer[n]==16'hffff;
    end
    always_ff @(posedge clk) if(ce) begin
        divider<=timer_tick?'0:divider+1'b1;
        for(int n=0;n<18;n++) begin
            if(!enabled[n] || restart[n]) timer[n]<=reload[n];
            else if(run && timer_tick) timer[n]<=due[n]?reload[n]:timer[n]+1'b1;
        end
        if(config_we && config_addr<18) begin
            if(config_be[0])reload[config_addr][7:0]<=config_data[7:0];
            if(config_be[1])reload[config_addr][15:8]<=config_data[15:8];
        end
        if(rst) begin
            divider<='0;
            for(int n=0;n<18;n++)begin reload[n]<=0;timer[n]<=0;end
        end
    end
endmodule
