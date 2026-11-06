// SPDX-License-Identifier: MIT
// The APF side's write path (core_top_ds SHELL_CPU = 2), on clk_74a: what is
// left of nds_apf_host once SERV runs the command protocol (nds_mbox,
// sw/scpu). Bridge writes become SDRAM writes into the write FIFO, as
// nds_apf_host's:
//   0x10000000 + region * 1 MiB + o   BIOS9, BIOS7, firmware, nds_boot.bin:
//                                     SDRAM byte 0x0800000 + region * 1 MiB + o
//   NDT_WIN + o                       the plugin's tables, at NDT_BASE_W + o/4
//   SAVE_WIN + o                      the save, at SAVE_BASE_W + o/4
//   fetch window (nds_mbox fw_*)      ROM-cache slot fw_slot, word fw_word
// and a marker (SERV toggles sh_mark when the APF reports the fetch done;
// its error code sh_err) follows the fetch's data through the FIFO. At
// power-up one write of 0 to the tables' magic goes first.
`default_nettype none
module nds_apf_wr #(
    parameter [31:0] NDT_WIN = 32'h3000_0000,
    parameter [23:0] NDT_BASE_W = 24'h2F_FC00,
    parameter [23:0] CACHE_BASE_W = 24'h40_0000,
    parameter [23:0] SYS_BASE_W = 24'h20_0000,
    parameter integer SAVE_POS = -1,
    parameter [31:0] SAVE_WIN = 32'h6000_0000,
    parameter [23:0] SAVE_BASE_W = 24'h04_0000
) (
    input wire clk, reset,
    input wire bridge_wr,
    input wire [31:0] bridge_addr, bridge_wr_data,
    input wire fw_v,
    input wire [13:0] fw_slot,
    input wire [9:0] fw_word,
    input wire [31:0] fw_data,
    input wire sh_mark,                     // toggle (clk_bus); sh_err set with it
    input wire [2:0] sh_err,
    output reg f_wr = 0,
    output reg [56:0] f_data = 0
);
    (* async_reg = "true" *) reg [2:0] mk_s = 0;
    (* async_reg = "true" *) reg [2:0] er_s1 = 0, er_s = 0;
    reg mk_pend = 0, clr_pend = 1;
    wire in_load = bridge_addr[31:22] == 10'b0001_0000_00;
    wire in_ndt = bridge_addr[31:20] == NDT_WIN[31:20];
    wire in_save = SAVE_POS >= 0 && bridge_addr[31:20] == SAVE_WIN[31:20];
    always @(posedge clk) begin
        mk_s <= {mk_s[1:0], sh_mark}; er_s1 <= sh_err; er_s <= er_s1;
        if (mk_s[2] != mk_s[1]) mk_pend <= 1;
        f_wr <= 0;
        if (reset) ;
        else if (fw_v) begin
            f_wr <= 1; f_data <= {1'b0, CACHE_BASE_W + {fw_slot, 10'b0} + {14'b0, fw_word}, fw_data};
        end else if (bridge_wr && in_load) begin
            f_wr <= 1;
            f_data <= {1'b0, SYS_BASE_W + {2'b0, bridge_addr[21:20], 18'b0} + {4'b0, bridge_addr[19:2]}, bridge_wr_data};
        end else if (bridge_wr && in_ndt) begin
            f_wr <= 1; f_data <= {1'b0, NDT_BASE_W + {6'b0, bridge_addr[19:2]}, bridge_wr_data};
        end else if (bridge_wr && in_save) begin
            f_wr <= 1; f_data <= {1'b0, SAVE_BASE_W + {6'b0, bridge_addr[19:2]}, bridge_wr_data};
        end else if (clr_pend && !bridge_wr) begin
            clr_pend <= 0; f_wr <= 1; f_data <= {1'b0, NDT_BASE_W, 32'h0};
        end else if (mk_pend && !bridge_wr) begin
            // the APF reported done after its last data write; the fetch pipeline (three clocks) is long empty
            mk_pend <= 0; f_wr <= 1; f_data <= {1'b1, 24'b0, 29'b0, er_s};
        end
        if (reset) begin clr_pend <= 1; mk_pend <= 0; end
    end
endmodule
`default_nettype wire
