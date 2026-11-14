# Timing receipt (docs/plan-full-core.md section 5, AGENTS.md "Plan and fit
# process" rule 3): TNS and failing-endpoint counts per clock and per cone,
# with the worst path's clock relationship, for every operating condition
# (setup) and the fast ones (hold). Sourced by scripts/build_ds.sh's STA
# script on an open timing netlist; writes timing_receipt.txt:
#   SETUP|HOLD <corner> <clock> wns <ns> tns <ns> failing <n>
#   WORST <corner> <clock> slack <ns> req <ns, the clock relationship> launch <clock> latch <clock> from <node> to <node>
#   CONE <SETUP|HOLD> <corner> <clock> <cone> tns <ns> failing <n>
# A cone is the hierarchy level under nds_top (nds_disp and nds_gpu3d one
# level deeper), or core_top's own level for the shell, so a receipt names
# the unit that holds the failing endpoints, not only the worst three paths.
# The endpoint list is capped at TR_MAX per clock and analysis (marked).

set TR_MAX 200000

proc tr_cone {name} {
    if {[regexp {nds_top:[^|]+\|([A-Za-z0-9_]+):[^|]+\|([A-Za-z0-9_]+):} $name -> e e2]} {
        if {$e eq "nds_disp" || $e eq "nds_gpu3d"} { return "$e/$e2" }
        return $e
    }
    if {[regexp {nds_top:[^|]+\|([A-Za-z0-9_]+):} $name -> e]} { return $e }
    if {[regexp {core_top:[^|]+\|([A-Za-z0-9_]+):} $name -> e]} { return "core_top/$e" }
    if {[regexp {^core_top:[^|]+\|} $name]} { return "core_top" }
    return "shell"
}

proc tr_one {fh kind corner} {
    global TR_MAX
    foreach_in_collection c [all_clocks] {
        set n [get_clock_info -name $c]
        if {$kind eq "SETUP"} {
            set paths [get_timing_paths -setup -to_clock $n -less_than_slack 0 -npaths $TR_MAX -nworst 1]
            set w [get_timing_paths -setup -to_clock $n -npaths 1]
        } else {
            set paths [get_timing_paths -hold -to_clock $n -less_than_slack 0 -npaths $TR_MAX -nworst 1]
            set w [get_timing_paths -hold -to_clock $n -npaths 1]
        }
        set tns 0.0; set cnt 0
        array unset ct; array unset cn
        foreach_in_collection p $paths {
            set s [get_path_info $p -slack]
            set to [get_node_info -name [get_path_info $p -to]]
            set k [tr_cone $to]
            set tns [expr {$tns + $s}]; incr cnt
            if {![info exists ct($k)]} { set ct($k) 0.0; set cn($k) 0 }
            set ct($k) [expr {$ct($k) + $s}]; incr cn($k)
        }
        set wns "-"
        foreach_in_collection p $w {
            set wns [format %.3f [get_path_info $p -slack]]
            set lc [get_path_info $p -from_clock]; set tc [get_path_info $p -to_clock]
            set lcn [expr {$lc eq "" ? "-" : [get_clock_info -name $lc]}]
            set tcn [expr {$tc eq "" ? "-" : [get_clock_info -name $tc]}]
            puts $fh [format "WORST %s %s %s slack %s req %.3f launch %s latch %s from %s to %s" $kind $corner $n $wns \
                [get_path_info $p -clock_relationship] $lcn $tcn [get_node_info -name [get_path_info $p -from]] \
                [get_node_info -name [get_path_info $p -to]]]
        }
        puts $fh [format "%s %s %s wns %s tns %.3f failing %d%s" $kind $corner $n $wns $tns $cnt \
            [expr {$cnt >= $TR_MAX ? " (capped)" : ""}]]
        foreach k [lsort [array names ct]] {
            puts $fh [format "CONE %s %s %s %s tns %.3f failing %d" $kind $corner $n $k $ct($k) $cn($k)]
        }
    }
}

proc timing_receipt {file} {
    set fh [open $file w]
    foreach cond [get_available_operating_conditions] {
        set_operating_conditions $cond
        update_timing_netlist
        tr_one $fh SETUP $cond
        if {[string match "*fast*" [string tolower $cond]] || [string match "*MIN_FAST*" $cond]} {
            tr_one $fh HOLD $cond
        }
    }
    close $fh
}
