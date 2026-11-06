// Measurement-only adaptation of sim/ds_dev/nds_spi_sys.sv at 63052f05.
// Keeps existing SPI pins; adds independent WiFi and AUX traffic.
// Shared engine behind nds_spi pins, with configurable memory latency and
// concurrent WiFi RAM/timer work plus EEPROM status events. Measurement only.
`default_nettype none
module nds_spi_service_sys (
    input  logic        clk, rst, tick,
    input  logic        io_req, io_we,
    input  logic [3:0]  io_be,
    input  logic [31:0] io_wdata,
    output logic [31:0] io_rdata,
    output logic        irq, pwr_off,
    output logic        fw_req,
    output logic [17:2] fw_addr,
    input  logic        fw_ack,
    input  logic [31:0] fw_rdata,
    input  logic        pen,
    input  logic [7:0]  tx, ty,
    input  logic [15:0] kx, ky, ox, oy,
    output logic        pen_down,
    output logic        ready          // the engine's reset sequence is done
);
    logic        ev, sdw, done, frsh, flush, fwait, fstop, wm_req, wm_ack = 1'b0;
    logic [15:0] w, tprd, toff, tst;
    logic [7:0]  sd;
    nds_spi_mc u_spi (.clk, .rst, .tick, .io_req, .io_we, .io_be, .io_wdata, .io_rdata, .irq,
        .pen, .tx, .ty, .kx, .ky, .ox, .oy, .pen_down,
        .ev, .ev_w(w), .t_prd(tprd), .t_off(toff), .t_st(tst),
        .e_sdw(sdw), .e_sd(sd), .e_done(done), .e_frsh(frsh), .e_flush(flush), .e_fwait(fwait), .e_fstop(fstop),
        .fw_req, .fw_addr, .fw_ack, .fw_rdata);
    nds_wifi_mc #(.SPI(1), .AUX(1)) u_eng (.clk, .rst, .tick, .power(service_wifi != 0), .id_lite(1'b1),
        .wf_req, .wf_we, .wf_be, .wf_addr, .wf_wdata, .wf_ack, .wf_rdata, .irq(),
        .wm_req, .wm_we, .wm_addr, .wm_be, .wm_wdata, .wm_ack, .wm_rdata,
        .spi_ev(ev), .spi_w(w), .spi_tprd(tprd), .spi_toff(toff), .spi_tst(tst),
        .spi_sdw(sdw), .spi_sd(sd), .spi_done(done), .spi_frsh(frsh), .spi_flush(flush), .spi_fwait(fwait),
        .spi_fstop(fstop), .spi_pwoff(pwr_off),
        .aux_ev, .aux_w, .aux_w2(16'h0200), .aux_sdw(), .aux_sd, .aux_done, .aux_op(), .aux_b0());
    // Memory and concurrent clients are defined below.
    // Initialization completion stays true through memory waits and dispatch.
    // Gating observation by IDLE/RUN would miss IRQs while WiFi owns SDRAM.
    assign ready = u_eng.est != u_eng.E_INIT_RF && u_eng.est != u_eng.E_INIT_MEM && u_eng.est != u_eng.E_INIT_REG;
    integer service_wifi=0, service_aux=0, service_memlat=1;
    initial begin
        void'($value$plusargs("service_wifi=%d",service_wifi));
        void'($value$plusargs("service_aux=%d",service_aux));
        void'($value$plusargs("service_memlat=%d",service_memlat));
        if(service_memlat<1) $fatal(1,"SERVICE_FAIL invalid memory latency");
    end
    logic wf_req=0,wf_we=0,wf_ack; logic [3:0] wf_be=0;
    logic [23:2] wf_addr=0;logic [31:0] wf_wdata=0,wf_rdata;
    logic wm_we;logic [20:2] wm_addr;logic [3:0] wm_be;logic [31:0] wm_wdata,wm_rdata=0;
    logic aux_ev=0,aux_done;logic [15:0] aux_w=0;logic [7:0] aux_sd;
    logic [31:0] memory [integer];
    logic mem_pending=0,mem_release=0,mem_we;integer mem_left,mem_addr;
    logic [31:0] mem_data;logic [3:0] mem_be;
    longint cycles=0,wifi_transactions=0,aux_transactions=0,timer_steps=0,timer_due=0;
    longint spi_events=0,spi_age=0,spi_age_max=0,engine_hold_ticks=0,firmware_hold_ticks=0;
    longint wf_latency_max=0,aux_latency_max=0;
    longint wifi_spi_overlap=0,aux_spi_overlap=0;
    longint spi_fast_events=0,spi_fast_age_max=0,fast_engine_hold_ticks=0;
    always @(posedge clk) begin
        cycles++;
        wm_ack<=0;
        if(mem_release) begin if(!wm_req) mem_release<=0;end
        else if(mem_pending) begin
            if(mem_left>1) mem_left<=mem_left-1;
            else begin
                if(mem_we) begin
                    if(!memory.exists(mem_addr)) memory[mem_addr]=0;
                    for(integer b=0;b<4;b++) if(mem_be[b]) memory[mem_addr][b*8+:8]=mem_data[b*8+:8];
                end else wm_rdata<=memory.exists(mem_addr)?memory[mem_addr]:0;
                wm_ack<=1;mem_pending<=0;mem_release<=1;
            end
        end else if(wm_req) begin
            mem_pending<=1;mem_left<=service_memlat;mem_addr<=int'(wm_addr);
            mem_we<=wm_we;mem_data<=wm_wdata;mem_be<=wm_be;
        end
        if(!rst && u_eng.power_on && tick && u_eng.pcnt==1) timer_due++;
        if(u_eng.est==u_eng.E_IDLE && u_eng.step_pend) timer_steps++;
        if(timer_due-timer_steps>1) $fatal(1,"SERVICE_FAIL timer event lost under contention");
        if(ev) spi_age++;else spi_age=0;
        if(done) begin
            spi_events++;if(spi_age>spi_age_max) spi_age_max=spi_age;
            if(u_spi.baud==0) begin spi_fast_events++;if(spi_age>spi_fast_age_max) spi_fast_age_max=spi_age;end
        end
        if(!rst && u_spi.busy && tick && u_spi.tmr==0) begin
            if(ev) begin engine_hold_ticks++;if(u_spi.baud==0) fast_engine_hold_ticks++;end
            if(u_spi.f_wait) firmware_hold_ticks++;
        end
    end
    task automatic wifi_access(input logic wr,input [23:0] address,input [3:0] be,input [31:0] data,output [31:0] answer);
        longint start;
        @(negedge clk);wf_req=1;wf_we=wr;wf_addr=address>>2;wf_be=be;wf_wdata=data;start=cycles;
        if(u_spi.busy) wifi_spi_overlap++;
        // wf_req is an event pulse; address/data stay held through the answer.
        @(negedge clk);wf_req=0;
        wait(wf_ack);@(negedge clk);answer=wf_rdata;
        if(cycles-start>wf_latency_max) wf_latency_max=cycles-start;
        wifi_transactions++;
        wf_req=0;
        repeat(2) @(negedge clk);
    endtask
    initial begin : wifi_client
        reg [31:0] answer,pattern;
        wait(!rst && ready);
        if(service_wifi) begin
            // Enable the existing timer unit; upper halfword at offset 0x36.
            wifi_access(1,24'h800036,4'hc,0,answer);
            for(integer i=0;;i++) begin
                pattern=32'h51a70000^i;
                wifi_access(1,24'h804000+4*(i%8),4'hf,pattern,answer);
                wifi_access(0,24'h804000+4*(i%8),4'hf,0,answer);
                if(answer!==pattern) $fatal(1,"SERVICE_FAIL WiFi RAM %08x expected %08x",answer,pattern);
                repeat(8) @(negedge clk);
            end
        end
    end
    task automatic aux_byte(input [15:0] word,input [7:0] expected);
        longint start;
        @(negedge clk);aux_w=word;aux_ev=1;start=cycles;
        if(u_spi.busy) aux_spi_overlap++;
        wait(aux_done);
        if(aux_sd!==expected) $fatal(1,"SERVICE_FAIL AUX reply %02x expected %02x",aux_sd,expected);
        if(cycles-start>aux_latency_max) aux_latency_max=cycles-start;
        aux_transactions++;
        @(negedge clk);aux_ev=0;
        repeat(2) @(negedge clk);
    endtask
    initial begin
        wait(!rst && ready);
        if(service_aux) forever begin
            // EEPROM WREN, RDSR, WRDI, RDSR. No save-memory backend claim.
            aux_byte(16'h2006,8'h00);aux_byte(16'h2005,8'hff);aux_byte(16'h2100,8'h02);
            aux_byte(16'h2004,8'h00);aux_byte(16'h2005,8'hff);aux_byte(16'h2100,8'h00);
            repeat(8) @(negedge clk);
        end
    end
    final $display("SERVICE wifi=%0d aux=%0d memlat=%0d wifi_transactions=%0d aux_transactions=%0d timer_due=%0d timer_steps=%0d spi_events=%0d spi_age_max=%0d engine_hold_ticks=%0d firmware_hold_ticks=%0d wifi_latency_max=%0d aux_latency_max=%0d wifi_spi_overlap=%0d aux_spi_overlap=%0d spi_fast_events=%0d spi_fast_age_max=%0d fast_engine_hold_ticks=%0d",
        service_wifi,service_aux,service_memlat,wifi_transactions,aux_transactions,timer_due,timer_steps,spi_events,spi_age_max,engine_hold_ticks,firmware_hold_ticks,wf_latency_max,aux_latency_max,wifi_spi_overlap,aux_spi_overlap,spi_fast_events,spi_fast_age_max,fast_engine_hold_ticks);
endmodule
`default_nettype wire
