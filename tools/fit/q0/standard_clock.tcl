# Standard queries require typed collections, not foreach object IDs as filters.
# Root2165 runtime logs pin this distinction. All unknown/ambiguous domains fail.
proc q0_filter {name} {
    return [regsub -all {[][\\*?]} $name {\\&}]
}
proc q0_name_patterns {name} {
    # Some TimeQuest filters use instance paths while info returns entity:instance.
    # All candidates are verified by exact canonical identity before use.
    set instance [regsub -all {(^|\|)[^|:]+:} $name {\1}]
    set out {}
    foreach n [list $name $instance] {
        foreach p [list $n [q0_filter $n] "*|$n" "*|[q0_filter $n]"] {
            if {$p ni $out} {lappend out $p}
        }
    }
    return $out
}
proc q0_regset {r} {
    set name [get_register_info -name $r];set seen {}
    # TimeQuest name matching differs from Tcl glob matching. Try its canonical
    # name first; a normalization is accepted only with exact identity roundtrip.
    foreach pattern [q0_name_patterns $name] {
        # Query the exact physical register, not its automatically generated
        # copies. all_registers visits each copy separately, so this preserves
        # coverage while avoiding an ambiguous two-object query for the parent.
        # Standard get_registers documents this default duplicate expansion.
        set col [get_registers -no_duplicates -nowarn $pattern];lappend seen [get_collection_size $col]
        if {[get_collection_size $col]==1} {
            set canonical ""
            foreach_in_collection got $col {set canonical [get_register_info -name $got]}
            if {$canonical eq $name} {return $col}
        }
    }
    error "not one named register: $name lookup_counts=$seen"
}
proc q0_clockset {c} {
    set name [get_clock_info -name $c];set seen {}
    foreach pattern [q0_name_patterns $name] {
        set col [get_clocks -nowarn $pattern];lappend seen [get_collection_size $col]
        if {[get_collection_size $col]==1} {
            set canonical ""
            foreach_in_collection got $col {set canonical [get_clock_info -name $got]}
            if {$canonical eq $name} {return $col}
        }
    }
    error "not one named clock: $name lookup_counts=$seen"
}
proc q0_clock_index {} {
    set clocks [dict create];set targets {};set children [dict create]
    foreach_in_collection c [all_clocks] {
        set name [get_clock_info -name $c]
        dict set clocks $name $c
        dict set children $name [get_clock_info -child_clocks $c]
        set ct [get_clock_info -targets $c]
        if {[get_collection_size $ct]!=1} {error "multiple defining clock targets or no target: $name"}
        foreach_in_collection t $ct {
            lappend targets [list $name $ct [get_node_info -name $t] [get_node_info -type $t]]
        }
    }
    foreach name [dict keys $clocks] {
        foreach child [dict get $children $name] {
            if {![dict exists $clocks $child]} {error "unknown child clock: $child"}
        }
    }
    return [list $clocks $targets $children]
}
proc q0_descendant {parent child children} {
    set pending [dict get $children $parent];set seen {}
    while {[llength $pending]>0} {
        set c [lindex $pending 0];set pending [lrange $pending 1 end]
        if {$c eq $child} {return 1}
        if {$c in $seen} {continue}
        lappend seen $c;set pending [concat $pending [dict get $children $c]]
    }
    return 0
}
proc q0_register_clock {r index} {
    lassign $index clocks targets children
    set matched {};set matched_targets {};set roots {}
    set regs [q0_regset $r]
    foreach_in_collection n [get_fanins -clock $regs] {lappend roots [get_node_info -name $n]}
    foreach record $targets {
        lassign $record name targetset targetname kind
        if {$kind in {port reg}} {
            # Standard forbids ports in -through. Root ports/register clocks
            # are compared against the actual clock-fanin roots instead.
            set reached [expr {[lsearch -exact $roots $targetname]>=0}]
        } else {
            set reached [expr {[get_collection_size [get_fanins -clock -through $targetset $regs]]>0}]
        }
        if {$reached} {
            if {$name ni $matched} {lappend matched $name}
            lappend matched_targets [list $name $targetname]
        }
    }
    set nearest {}
    foreach c $matched {
        set ancestor 0
        foreach d $matched {if {$c ne $d && [q0_descendant $c $d $children]} {set ancestor 1}}
        if {!$ancestor} {lappend nearest $c}
    }
    # all_registers also enumerates vendor configuration placeholders with no
    # physical clock arc. They are never FAST endpoints or MCP recipients.
    # A clocked-but-unresolved register still fails; Q0 consumers independently
    # require an actual SYS/FAST domain in the collector and production guard.
    if {[llength $nearest]==0 && [llength $roots]==0 && [llength [get_register_info -clock_edges $r]]==0} {
        puts "Q0_UNCLOCKED_NODE [get_register_info -name $r]"
        return Q0_UNCLOCKED_NODE
    }
    if {[llength $nearest]!=1} {error "unknown/multiple clock targets for [get_register_info -name $r]: $matched_targets"}
    return [lindex $nearest 0]
}
