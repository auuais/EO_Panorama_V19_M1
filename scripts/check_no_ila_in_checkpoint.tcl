set project_root [file normalize [file join [file dirname [info script]] ..]]
set top KintexTop_EO_IR_HD_SDI_panorama_base
set dcpfile [file join $project_root EO_Panorama_V19_M1.runs impl_1 "${top}_routed.dcp"]

if {![file exists $dcpfile]} {
    error "Routed checkpoint not found: $dcpfile"
}

open_checkpoint $dcpfile

set name_matches [get_cells -hier -quiet -filter {NAME =~ "*dbg_ila*"}]
set ref_matches  [get_cells -hier -quiet -filter {REF_NAME =~ "ila*"}]
set debug_cores [list]
if {[llength [info commands get_debug_cores]]} {
    set debug_cores [get_debug_cores -quiet]
}
set unexpected_debug_cores [list]
foreach debug_core $debug_cores {
    if {($debug_core eq "dbg_hub") ||
        [string match "*/u_ddr4_sub64" $debug_core] ||
        [string match "*u_ddr4_sub64" $debug_core]} {
        continue
    }
    lappend unexpected_debug_cores $debug_core
}

puts "NO_ILA_CHECK name_matches=[llength $name_matches] ref_matches=[llength $ref_matches] debug_cores=$debug_cores"
if {[llength $name_matches] || [llength $ref_matches] || [llength $unexpected_debug_cores]} {
    puts "name_matches=$name_matches"
    puts "ref_matches=$ref_matches"
    puts "debug_cores=$debug_cores"
    puts "unexpected_debug_cores=$unexpected_debug_cores"
    error "Production checkpoint ILA policy failed"
}

close_design
