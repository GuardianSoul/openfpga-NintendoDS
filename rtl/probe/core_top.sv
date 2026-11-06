// SPDX-License-Identifier: MIT
// Pocket top for the SD data-slot read probe (docs/sd-probe.md). The APF
// shell (apf_top and friends, rtl/apf/) is MIRLO64's copy of the
// Analogue template, the same one openfpga-PlayStation's hardware probes use. Only the
// bridge, the target command, video and silent audio are used; every memory
// and cartridge pin is parked.
//
// Data slots (data.json order matters: slot k's size is data-table word 2k+1):
//   0: ROM, ID 1, not deferred: the Pocket loads it to bridge 0x00000000 at
//      start-up (timed, not stored); then the probe reads it again through
//      target_dataslot_read into a window at 0x30000000
//   1: probe log, ID 2, nonvolatile, saved by the Pocket from bridge 0x40000000
//      when the core quits; its size goes into data-table word 3.
`default_nettype none
module core_top (
    input wire clk_74a,
    input wire clk_74b,
    inout  wire [7:0] cart_tran_bank2,
    output wire       cart_tran_bank2_dir,
    inout  wire [7:0] cart_tran_bank3,
    output wire       cart_tran_bank3_dir,
    inout  wire [7:0] cart_tran_bank1,
    output wire       cart_tran_bank1_dir,
    inout  wire [7:4] cart_tran_bank0,
    output wire       cart_tran_bank0_dir,
    inout  wire cart_tran_pin30,
    output wire cart_tran_pin30_dir,
    output wire cart_pin30_pwroff_reset,
    inout  wire cart_tran_pin31,
    output wire cart_tran_pin31_dir,
    input  wire port_ir_rx,
    output wire port_ir_tx,
    output wire port_ir_rx_disable,
    inout  wire port_tran_si,
    output wire port_tran_si_dir,
    inout  wire port_tran_so,
    output wire port_tran_so_dir,
    inout  wire port_tran_sck,
    output wire port_tran_sck_dir,
    inout  wire port_tran_sd,
    output wire port_tran_sd_dir,
    output wire [21:16] cram0_a,
    inout  wire [ 15:0] cram0_dq,
    input  wire         cram0_wait,
    output wire         cram0_clk,
    output wire         cram0_adv_n,
    output wire         cram0_cre,
    output wire         cram0_ce0_n,
    output wire         cram0_ce1_n,
    output wire         cram0_oe_n,
    output wire         cram0_we_n,
    output wire         cram0_ub_n,
    output wire         cram0_lb_n,
    output wire [21:16] cram1_a,
    inout  wire [ 15:0] cram1_dq,
    input  wire         cram1_wait,
    output wire         cram1_clk,
    output wire         cram1_adv_n,
    output wire         cram1_cre,
    output wire         cram1_ce0_n,
    output wire         cram1_ce1_n,
    output wire         cram1_oe_n,
    output wire         cram1_we_n,
    output wire         cram1_ub_n,
    output wire         cram1_lb_n,
    output wire [12:0] dram_a,
    output wire [ 1:0] dram_ba,
    inout  wire [15:0] dram_dq,
    output wire [ 1:0] dram_dqm,
    output wire        dram_clk,
    output wire        dram_cke,
    output wire        dram_ras_n,
    output wire        dram_cas_n,
    output wire        dram_we_n,
    output wire [16:0] sram_a,
    inout  wire [15:0] sram_dq,
    output wire        sram_oe_n,
    output wire        sram_we_n,
    output wire        sram_ub_n,
    output wire        sram_lb_n,
    input wire vblank,
    output wire dbg_tx,
    input  wire dbg_rx,
    output wire user1,
    input  wire user2,
    inout  wire aux_sda,
    output wire aux_scl,
    output wire vpll_feed,
    output wire [23:0] video_rgb,
    output wire        video_rgb_clock,
    output wire        video_rgb_clock_90,
    output wire        video_de,
    output wire        video_skip,
    output wire        video_vs,
    output wire        video_hs,
    output wire audio_mclk,
    input  wire audio_adc,
    output wire audio_dac,
    output wire audio_lrck,
    output wire        bridge_endian_little,
    input  wire [31:0] bridge_addr,
    input  wire        bridge_rd,
    output reg  [31:0] bridge_rd_data,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_wr_data,
    input wire [31:0] cont1_key,
    input wire [31:0] cont2_key,
    input wire [31:0] cont3_key,
    input wire [31:0] cont4_key,
    input wire [31:0] cont1_joy,
    input wire [31:0] cont2_joy,
    input wire [31:0] cont3_joy,
    input wire [31:0] cont4_joy,
    input wire [15:0] cont1_trig,
    input wire [15:0] cont2_trig,
    input wire [15:0] cont3_trig,
    input wire [15:0] cont4_trig
);
    assign port_ir_tx = 0, port_ir_rx_disable = 1;
    assign cart_tran_bank1 = 8'bz, cart_tran_bank2 = 8'bz, cart_tran_bank3 = 8'bz;
    assign cart_tran_bank1_dir = 0, cart_tran_bank2_dir = 0, cart_tran_bank3_dir = 0;
    assign cart_tran_bank0 = 4'hf, cart_tran_bank0_dir = 1;
    assign cart_tran_pin30 = 1'bz, cart_tran_pin30_dir = 0, cart_pin30_pwroff_reset = 0;
    assign cart_tran_pin31 = 1'bz, cart_tran_pin31_dir = 0;
    assign port_tran_si = 1'bz, port_tran_so = 1'bz, port_tran_sck = 1'bz, port_tran_sd = 1'bz;
    assign port_tran_si_dir = 0, port_tran_so_dir = 0, port_tran_sck_dir = 0, port_tran_sd_dir = 0;
    assign sram_a = 0, sram_dq = 16'bz, sram_oe_n = 1, sram_we_n = 1, sram_ub_n = 1, sram_lb_n = 1;
    assign dram_a = 0, dram_ba = 0, dram_dq = 16'bz, dram_dqm = 2'b11, dram_clk = 0, dram_cke = 0;
    assign dram_ras_n = 1, dram_cas_n = 1, dram_we_n = 1;
    assign cram0_a = 0, cram0_dq = 16'bz, cram0_clk = 0, cram0_adv_n = 1, cram0_cre = 0,
        cram0_ce0_n = 1, cram0_ce1_n = 1, cram0_oe_n = 1, cram0_we_n = 1, cram0_ub_n = 1, cram0_lb_n = 1;
    assign cram1_a = 0, cram1_dq = 16'bz, cram1_clk = 0, cram1_adv_n = 1, cram1_cre = 0,
        cram1_ce0_n = 1, cram1_ce1_n = 1, cram1_oe_n = 1, cram1_we_n = 1, cram1_ub_n = 1, cram1_lb_n = 1;
    assign dbg_tx = 1'bz, user1 = 1'bz, aux_sda = 1'bz, aux_scl = 1'bz, vpll_feed = 1'bz;
    assign bridge_endian_little = 0;

    reg [7:0] power_count = 0;
    reg power_reset_n = 0;
    always @(posedge clk_74a) begin
        if (!power_reset_n) power_count <= power_count + 1'b1;
        if (&power_count) power_reset_n <= 1;
    end

    // ---- APF commands
    wire reset_n, dataslot_allcomplete;
    wire [31:0] cmd_bridge_rd_data;
    wire tgt_read, tgt_ack, tgt_done;
    wire [2:0] tgt_err;
    wire [15:0] tgt_id;
    wire [31:0] tgt_offset, tgt_bridge, tgt_length;
    wire [9:0] dt_addr;
    wire dt_wren;
    wire [31:0] dt_data, dt_q;
    core_bridge_cmd commands (
        .clk(clk_74a), .reset_n(reset_n),
        .bridge_endian_little(bridge_endian_little), .bridge_addr(bridge_addr), .bridge_rd(bridge_rd),
        .bridge_rd_data(cmd_bridge_rd_data), .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
        .status_boot_done(power_reset_n), .status_setup_done(power_reset_n), .status_running(reset_n),
        .dataslot_requestread(), .dataslot_requestread_id(), .dataslot_requestread_ack(1'b1), .dataslot_requestread_ok(1'b1),
        .dataslot_requestwrite(), .dataslot_requestwrite_id(), .dataslot_requestwrite_size(),
        .dataslot_requestwrite_ack(1'b1), .dataslot_requestwrite_ok(1'b1),
        .dataslot_update(), .dataslot_update_id(), .dataslot_update_size(),
        .dataslot_allcomplete(dataslot_allcomplete),
        .rtc_epoch_seconds(), .rtc_date_bcd(), .rtc_time_bcd(), .rtc_valid(),
        .savestate_supported(1'b0), .savestate_addr(32'b0), .savestate_size(32'b0), .savestate_maxloadsize(32'b0),
        .osnotify_inmenu(),
        .savestate_start(), .savestate_start_ack(1'b0), .savestate_start_busy(1'b0), .savestate_start_ok(1'b0), .savestate_start_err(1'b0),
        .savestate_load(), .savestate_load_ack(1'b0), .savestate_load_busy(1'b0), .savestate_load_ok(1'b0), .savestate_load_err(1'b0),
        .target_dataslot_read(tgt_read), .target_dataslot_write(1'b0),
        .target_dataslot_getfile(1'b0), .target_dataslot_openfile(1'b0),
        .target_dataslot_ack(tgt_ack), .target_dataslot_done(tgt_done), .target_dataslot_err(tgt_err),
        .target_dataslot_id(tgt_id), .target_dataslot_slotoffset(tgt_offset),
        .target_dataslot_bridgeaddr(tgt_bridge), .target_dataslot_length(tgt_length),
        .target_buffer_param_struct(32'b0), .target_buffer_resp_struct(32'b0),
        .datatable_addr(dt_addr), .datatable_wren(dt_wren), .datatable_data(dt_data), .datatable_q(dt_q));

    // ---- the probe
    wire [31:0] log_data;
    wire [1:0] probe_state;
    wire [13:0] case_state;
    wire stuck;
    wire [1:0] load_state;
    wire [15:0] records;
    localparam integer N = 64;
    sd_probe #(.N(N)) probe (
        .clk(clk_74a), .reset(!power_reset_n), .start(dataslot_allcomplete && reset_n),
        .slots_done(dataslot_allcomplete), .load_state(load_state),
        .dt_addr(dt_addr), .dt_wren(dt_wren), .dt_data(dt_data), .dt_q(dt_q),
        .tgt_read(tgt_read), .tgt_id(tgt_id), .tgt_offset(tgt_offset), .tgt_bridge(tgt_bridge),
        .tgt_length(tgt_length), .tgt_ack(tgt_ack), .tgt_done(tgt_done), .tgt_err(tgt_err),
        .bridge_wr(bridge_wr), .bridge_addr(bridge_addr), .bridge_wr_data(bridge_wr_data),
        .read_index(bridge_addr[16:2]), .read_data(log_data),
        .state_out(probe_state), .case_state(case_state), .stuck(stuck), .records(records));

    always @* begin
        bridge_rd_data = 0;
        if (bridge_addr[31:24] == 8'hF8) bridge_rd_data = cmd_bridge_rd_data;
        else if (bridge_addr[31:24] == 8'h40) bridge_rd_data = log_data;
    end

    // progress bar: records * 640 / (7 * N), as a 16.16 fixed-point step
    localparam [31:0] STEP = (640 * 65536 + 7 * N - 1) / (7 * N);
    reg [9:0] progress = 0;
    wire [31:0] progress_full = records * STEP;
    always @(posedge clk_74a) progress <= progress_full[25:16] > 10'd640 ? 10'd640 : progress_full[25:16];

    // ---- video: 640x480 at 25.2 MHz
    wire video_locked;
    altera_pll #(.fractional_vco_multiplier("true"), .reference_clock_frequency("74.25 MHz"),
        .operation_mode("normal"), .number_of_clocks(2), .pll_type("General"), .pll_subtype("General"),
        .output_clock_frequency0("25.200000 MHz"), .phase_shift0("0 ps"), .duty_cycle0(50),
        .output_clock_frequency1("25.200000 MHz"), .phase_shift1("9921 ps"), .duty_cycle1(50)) video_pll (
        .refclk(clk_74a), .rst(!power_reset_n), .fbclk(1'b0), .fboutclk(), .locked(video_locked),
        .outclk({video_rgb_clock_90, video_rgb_clock}));
    assign video_skip = 0;
    sd_probe_screen screen (.clk(video_rgb_clock), .reset(!video_locked),
        .state(probe_state), .case_state(case_state), .load_state(load_state), .stuck(stuck), .progress(progress),
        .rgb(video_rgb), .de(video_de), .hs(video_hs), .vs(video_vs));

    // ---- silent audio
    wire audio_sclk;
    mf_audio_pll audio_pll (.refclk(clk_74b), .rst(!power_reset_n),
        .outclk_0(audio_mclk), .outclk_1(audio_sclk), .locked());
    sound_i2s #(.SIGNED_INPUT(1)) sound (.audio_sclk(audio_sclk),
        .audio_l(16'b0), .audio_r(16'b0), .audio_lrck(audio_lrck), .audio_dac(audio_dac));
endmodule
`default_nettype wire
