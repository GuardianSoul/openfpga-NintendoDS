# SDRAM pin timing for the DS core (rtl/pocket/nds_sdram_mc.sv on clk_mem).
#
# scripts/build_ds.sh appends it to ds.sdc (the fitter closes these paths);
# tools/fit/sdram_io_sta.tcl reports them per corner on a fitted project
# (pass it this file only for a fit whose ds.sdc lacks it). The pin settings
# (I/O cell registers, D1_DELAY) are in build_ds.sh; docs/sdram-io.md.
#
# Part: AS4C32M16MSA-6BIN (Analogue openFPGA "external hardware" page; the same
# identification as openfpga-PlayStation docs/pocket-native-sdram-timing.md). Alliance
# Rev.1.0 datasheet (Dec 2017), "AC Characteristics", printed p.16 (-6 grade):
#   tAC(3) 5.5 ns max (clock to data, CL3)   tOH 2.5 ns min (output hold)
#   tCMS/tCAS/tCDS 2.0 ns min (command/address/data-in setup)
#   tCMH/tCAH/tCDH 1.0 ns min (hold)
# Board: each PCB leg (FPGA->SDRAM clock, FPGA<->SDRAM data/command) assumed
# 0..0.5 ns. Not measured; the same unqualified bound openfpga-PlayStation's released
# CAS3 SDRAM pin model uses (scripts/pocket_native_sdram_io.tcl).
#
# Clock geometry (nds_pll_ds.sv, nds_sdram_mc.sv): clk_mem = PLL output 1,
# 100.541946 MHz, phase 0. The chip clock dram_clk is clk_mem inverted by a
# DDIO output cell (datain_h 0, datain_l 1): the chip's rising edge is
# clk_mem's falling edge plus the propagated clock-out delay, which TimeQuest
# traces through the DDIO and pad. All pin registers (useioff) are on
# clk_mem's rising edge.
#
# Read capture contract (CL3, OUT_REG=1, RD_LAT=4): a READ leaves the pin
# registers at edge E1, the chip takes it at chip edge C0 = E1 + T/2, beat 0
# is launched by C0 + 2T (vendor Figure 2, p.9: CL3 data after T2 + tAC, held
# until T3 + tOH) and dq_in takes it at E1 + 4T = launch + 1.5T. That is one
# period after TimeQuest's default (next clk_mem rise after the launch edge,
# + T/2), hence the setup multicycle of 2. Hold keeps the default: the next
# beat (launched at C0 + 3T) must not arrive before the capture edge
# (launch + T/2). Same contract as openfpga-PlayStation's previous-beat.sdc.

# Post-fit STA on #1643 (main da920750, 1asR; tools/fit/sdram_io_sta.tcl),
# worst over the four corners (setup / hold, ns):
#   read  dram_dq -> dq_in      +2.082 (slow 85C) / -0.205 (fast 0C; 14 of 16
#         bits negative: the next beat can overwrite the captured one)
#   write a/ba/dqm/dq (IOE)     +1.243 / +3.187;  dq[10] OE -0.112 (slow 85C)
#   write ras_n/cas_n/we_n      -2.967 (slow 85C) / +3.2: p_cmd is extracted as
#         a state machine (map report "State Machine ... mc|p_cmd"), so the
#         three command pins are decoded from one-hot flops in the core, not
#         driven from I/O output registers (fit report: Output Register "no")

set sd_tac  5.5
set sd_toh  2.5
set sd_tsu  2.0
set sd_th   1.0
set sd_bmin 0.0
set sd_bmax 0.5

set sd_mem_pin [get_pins {ic|core_pll|pll|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
if {[get_collection_size $sd_mem_pin] != 1} { post_message -type error "nds_sdram_io.sdc: clk_mem PLL output not found" }
create_generated_clock -name sdram_clk_out -source $sd_mem_pin -divide_by 1 -invert [get_ports dram_clk]

set sd_in   [get_ports {dram_dq[*]}]
set sd_out  [get_ports {dram_a[*] dram_ba[*] dram_dqm[*] dram_dq[*] dram_ras_n dram_cas_n dram_we_n}]
set sd_caps [get_registers {*|nds_sdram_mc:mc|dq_in[*]}]
post_message -type info "nds_sdram_io.sdc: [get_collection_size $sd_in] inputs, [get_collection_size $sd_out] outputs, [get_collection_size $sd_caps] capture registers"

# read: launch at the chip edge; data valid from tOH (min) to tAC (max) after
# it, plus the clock leg out and the data leg back
set_input_delay  -clock sdram_clk_out -max [expr {$sd_tac + 2*$sd_bmax}] $sd_in
set_input_delay  -clock sdram_clk_out -min [expr {$sd_toh + 2*$sd_bmin}] $sd_in
set_multicycle_path -setup 2 -from $sd_in -to $sd_caps
# write/command: chip setup and hold plus the skew between the clock leg and
# the data/command leg
set_output_delay -clock sdram_clk_out -max [expr {$sd_tsu + $sd_bmax - $sd_bmin}] $sd_out
set_output_delay -clock sdram_clk_out -min [expr {-$sd_th + $sd_bmin - $sd_bmax}] $sd_out
# dram_cke is tied to 1: no timing
set_false_path -to [get_ports dram_cke]
