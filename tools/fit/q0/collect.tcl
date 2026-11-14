# Post-fit read-only TimeQuest collector. No constraints are created/changed.
source [file join [file dirname [info script]] standard_clock.tcl]
# quartus_sta -t collect.tcl PROJECT REVISION NEW_OUTPUT_DIRECTORY
proc q0_emit {channel args} {
    foreach v $args {if {[regexp {[\t\r\n]} $v]} {error "non-TSV value"}}
    puts $channel [join $args \t]
}
proc q0_new {name} {
    expr {[string match {*gpu3d_factor_pump:*} $name] || [string match {*q0_fast_*} $name] || [string match {*q0_sys_*} $name]}
}
proc q0_collect {out} {
    file mkdir $out
    set meta [open [file join $out inventory.tsv] w]
    set arcs [open [file join $out arcs.tsv] w]
    set paths [open [file join $out paths.tsv] w]
    set sys {};set fast {};set clkids [dict create]
    foreach_in_collection c [all_clocks] {
        set n [get_clock_info -name $c]
        dict set clkids $n $c
        if {[string first {general[5].gpll~PLL_OUTPUT_COUNTER|divclk} $n]>=0} {lappend sys $n}
        if {[string first {general[7].gpll~PLL_OUTPUT_COUNTER|divclk} $n]>=0} {lappend fast $n}
    }
    if {[llength $sys]!=1 || [llength $fast]!=1} {error "Q0 requires one SYS/FAST clock"}
    set sys [lindex $sys 0];set fast [lindex $fast 0]
    foreach c [list $sys $fast] {q0_emit $meta clock $c [get_clock_info -period [dict get $clkids $c]]}
    set clock_index [q0_clock_index]
    set regmap [dict create];set allnew {};set legacy {};set newids {};set legacyids {}
    foreach_in_collection r [all_registers] {
        set n [get_register_info -name $r];set cs [list [q0_register_clock $r $clock_index]]
        dict set regmap $n [list $r $cs]
        set isnew [q0_new $n]
        if {$isnew} {
            if {[llength $cs]!=1 || [lindex $cs 0] ni [list $sys $fast]} {error "Q0 clock missing/ambiguous: $n $cs"}
            lappend allnew $n;lappend newids $r
        } elseif {$fast in $cs} {lappend legacy $n;lappend legacyids $r}
        # Complete inventory, not a sample or a hand-written cache allowlist.
        foreach c $cs {q0_emit $meta register $n $c $isnew}
    }
    if {[llength $allnew]==0 || [llength $legacy]==0} {error "empty Q0 or legacy endpoint inventory"}
    q0_emit $meta inventory_end [llength $allnew] [llength $legacy]
    set jobs {};set id 0
    foreach n [concat $allnew $legacy] {
        lassign [dict get $regmap $n] dest clocks
        set isnew [q0_new $n]
        set count 0
        foreach_in_collection src [get_fanins -synch [q0_regset $dest]] {
            set sn [get_node_info -name $src]
            if {![dict exists $regmap $sn]} {error "non-register Q0/legacy data fanin: $sn -> $n"}
            lassign [dict get $regmap $sn] source scs
            if {[llength $scs]!=1} {error "ambiguous fanin clock: $sn"}
            set sc [lindex $scs 0];set dc [lindex $clocks 0]
            if {!$isnew && $sc ne $sys} {continue}
            if {$isnew && $sc ni [list $sys $fast]} {error "unexpected Q0 launch domain: $sn $sc"}
            incr id;incr count
            q0_emit $arcs $id [expr {$isnew?"new":"legacy"}] $sn $n $sc $dc
            lappend jobs [list $id $source $dest]
        }
        q0_emit $meta fanin_count $n $count
        if {$isnew && $count==0} {error "Q0 endpoint has no synchronous data fanins: $n"}
    }
    close $arcs;close $meta
    # Full applied-exception reports are additional gates, not just SDC text.
    set nc [get_registers -nowarn {__q0_empty_collection__}]
    foreach r $newids {set nc [add_to_collection $nc [q0_regset $r]]}
    foreach type {setup hold} {
        foreach direction {from to} {
            report_exceptions -$type -report_clock_groups -$direction $nc -npaths 0 -detail full_path -file [file join $out exceptions-$type-$direction.rpt]
        }
    }
    report_sdc -file [file join $out applied-sdc.rpt]
    report_sdc -ignored -file [file join $out ignored-sdc.rpt]
    foreach type {setup hold} {
        report_exceptions -$type -report_clock_groups -from_clock [q0_clockset [dict get $clkids $sys]] -to_clock [q0_clockset [dict get $clkids $fast]] -npaths 0 -detail full_path -file [file join $out legacy-exceptions-$type.rpt]
    }
    set conditions [get_available_operating_conditions]
    if {[llength $conditions]==0} {error "no operating conditions"}
    foreach corner $conditions {
        set_operating_conditions $corner;update_timing_netlist
        q0_emit $paths corner $corner
        foreach job $jobs {
            lassign $job id source dest
            foreach type {setup hold} {
                # One worst path for EACH structural register pair, no sample cap.
                set found [get_timing_paths -$type -from [q0_regset $source] -to [q0_regset $dest] -npaths 1]
                set cut [get_timing_paths -$type -false_path -from [q0_regset $source] -to [q0_regset $dest] -npaths 1]
                q0_emit $paths coverage $corner $id $type [get_collection_size $found] [get_collection_size $cut]
                foreach_in_collection p $found {
                    set vals {}
                    foreach key {type slack clock_relationship setup_start_multicycle setup_end_multicycle hold_start_multicycle hold_end_multicycle} {lappend vals [get_path_info -$key $p]}
                    q0_emit $paths path $corner $id $type [get_node_info -name [get_path_info -from $p]] [get_node_info -name [get_path_info -to $p]] [get_clock_info -name [get_path_info -from_clock $p]] [get_clock_info -name [get_path_info -to_clock $p]] {*}$vals
                }
            }
        }
        foreach type {setup hold} {
            report_timing -$type -to $nc -npaths [llength $allnew] -nworst 1 -detail full_path -file [file join $out new-$type-[string map {{ } _ / _} $corner].rpt]
        }
    }
    close $paths
    set f [open [file join $out complete.txt] w];puts $f Q0_COLLECTION_COMPLETE;close $f
}
if {![info exists ::Q0_COLLECTOR_LIBRARY]} {
    load_package sta
    lassign $quartus(args) project revision out
    if {[llength $quartus(args)]!=3} {error "usage: PROJECT REVISION NEW_OUTPUT_DIRECTORY"}
    if {[file exists $out]} {error "output already exists; refuse stale/mixed evidence"}
    project_open $project -revision $revision
    create_timing_netlist
    read_sdc
    update_timing_netlist
    q0_collect $out
    delete_timing_netlist
    project_close
}
