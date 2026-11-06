# Post-fit STA of the SDRAM pins (rtl/pocket/nds_sdram_io.sdc) on an existing
# full-chip DS fit, without refitting:
#   cp -a <fit dir> <copy>; cd <copy>
#   quartus_sta -t <repo>/tools/fit/sdram_io_sta.tcl [<repo>/rtl/pocket/nds_sdram_io.sdc]
# (the SDC argument only for a fit whose ds.sdc does not include it yet)
# Writes sdram_io.txt (summary per corner) and sdram_io_paths.txt (worst paths).
set sdc [lindex $quartus(args) 0]
project_open apf_top
create_timing_netlist
read_sdc
if {$sdc ne ""} { read_sdc $sdc }
if {[get_collection_size [get_clocks -nowarn sdram_clk_out]] != 1} { error "no sdram_clk_out clock: pass rtl/pocket/nds_sdram_io.sdc" }
update_timing_netlist
set out [open sdram_io.txt w]
set caps [get_registers {*|nds_sdram_mc:mc|dq_in[*]}]
set ins  [get_ports {dram_dq[*]}]
foreach cond [get_available_operating_conditions] {
  set_operating_conditions $cond
  update_timing_netlist
  foreach kind {setup hold} {
    set r [report_timing -$kind -from $ins -to $caps -npaths 16 -detail full_path -file sdram_io_paths.txt -append -panel_name "read $kind $cond"]
    puts $out [format "%-24s read  %-5s slack %8.3f  (%d paths)" $cond $kind [lindex $r 1] [lindex $r 0]]
    set r [report_timing -$kind -to_clock sdram_clk_out -npaths 40 -detail full_path -file sdram_io_paths.txt -append -panel_name "write $kind $cond"]
    puts $out [format "%-24s write %-5s slack %8.3f  (%d paths)" $cond $kind [lindex $r 1] [lindex $r 0]]
  }
}
report_timing -setup -from $ins -to $caps -npaths 16 -detail summary -file sdram_io_bits.txt -panel_name "read setup per bit"
report_timing -hold  -from $ins -to $caps -npaths 16 -detail summary -file sdram_io_bits.txt -append -panel_name "read hold per bit"
report_timing -setup -to_clock sdram_clk_out -npaths 40 -detail summary -file sdram_io_bits.txt -append -panel_name "write setup per pin"
report_timing -hold  -to_clock sdram_clk_out -npaths 40 -detail summary -file sdram_io_bits.txt -append -panel_name "write hold per pin"
report_clocks -file sdram_io_clocks.txt
close $out
delete_timing_netlist
project_close
