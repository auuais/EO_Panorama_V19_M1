set project_root [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $project_root EO_Panorama_V19_M1.xpr]
set_param general.maxThreads 8

proc parse_design_timing_summary {rpt} {
    set fh [open $rpt r]
    while {[gets $fh line] >= 0} {
        if {[regexp {^\s*(-?[0-9.]+)\s+(-?[0-9.]+)\s+\d+\s+\d+\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s+\d+\s+\d+\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s+\d+\s+\d+} $line -> wns tns whs ths wpws tpws]} {
            close $fh
            return [list $wns $tns $whs $ths $wpws $tpws]
        }
    }
    close $fh
    error "Could not parse Design Timing Summary in $rpt"
}

proc assert_nonnegative_timing {rpt} {
    set vals [parse_design_timing_summary $rpt]
    foreach {wns tns whs ths wpws tpws} $vals {break}
    puts "Routed timing summary: WNS=$wns TNS=$tns WHS=$whs THS=$ths WPWS=$wpws TPWS=$tpws"
    foreach name {WNS TNS WHS THS WPWS TPWS} value [list $wns $tns $whs $ths $wpws $tpws] {
        if {[expr {double($value) < 0.0}]} {
            error "Timing failed; refusing to write bitstream. $name=$value, report=$rpt"
        }
    }
}

proc assert_bus_skew_clean {rpt} {
    if {![file exists $rpt]} {
        error "Missing bus-skew report $rpt"
    }
    set fh [open $rpt r]
    set txt [read $fh]
    close $fh
    if {[regexp {Slack \(VIOLATED\)} $txt]} {
        error "Bus skew failed; refusing to write bitstream. report=$rpt"
    }
    puts "Bus skew report clean: $rpt"
}

set synth_run [get_runs synth_1]

# V19 bring-up edits must not reuse stale synthesized checkpoints.  The
# implementation is intentionally run as explicit Tcl commands below rather
# than via launch_runs impl_1: Vivado project runs can continue into their
# generated write_bitstream step before a Tcl-side timing guard regains
# control.  This script must never write a bitstream unless the routed timing
# reports have first been generated and parsed cleanly.
set_property AUTO_INCREMENTAL_CHECKPOINT 0 $synth_run
set_property INCREMENTAL_CHECKPOINT "" $synth_run

reset_run synth_1
launch_runs synth_1 -jobs 12
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
puts "synth_1 status: $synth_status"
if {![string match "*Complete*" $synth_status]} {
    error "synth_1 failed: $synth_status"
}

set top [get_property TOP [get_filesets sources_1]]
set synth_dir [get_property DIRECTORY $synth_run]
set synth_dcp [file join $synth_dir "${top}.dcp"]
if {![file exists $synth_dcp]} {
    error "Synthesized checkpoint not found: $synth_dcp"
}

set impl_dir [file join $project_root EO_Panorama_V19_M1.runs impl_1]
file mkdir $impl_dir
set bit_out [file join $impl_dir "${top}.bit"]
set ltx_out [file join $impl_dir "${top}.ltx"]

# Remove any previous implementation outputs so a failed guarded run cannot
# leave an old, mistakenly-programmable bitstream at the expected path.
foreach stale_file [list $bit_out $ltx_out] {
    if {[file exists $stale_file]} {
        file delete -force $stale_file
        puts "Removed stale output: $stale_file"
    }
}

set opt_dcp       [file join $impl_dir "${top}_opt.dcp"]
set placed_dcp    [file join $impl_dir "${top}_placed.dcp"]
set physopt_dcp   [file join $impl_dir "${top}_physopt.dcp"]
set routed_dcp    [file join $impl_dir "${top}_routed.dcp"]
set timing_rpt    [file join $impl_dir "${top}_timing_summary_routed.rpt"]
set bus_skew_rpt  [file join $impl_dir "${top}_bus_skew_routed.rpt"]
set route_rpt     [file join $impl_dir "${top}_route_status_routed.rpt"]

open_checkpoint $synth_dcp

opt_design
write_checkpoint -force $opt_dcp

place_design
write_checkpoint -force $placed_dcp

phys_opt_design
write_checkpoint -force $physopt_dcp

route_design
write_checkpoint -force $routed_dcp
report_route_status -file $route_rpt
report_timing_summary -max_paths 10 -routable_nets -report_unconstrained \
    -file $timing_rpt -warn_on_violation
report_bus_skew -file $bus_skew_rpt
assert_nonnegative_timing $timing_rpt
assert_bus_skew_clean $bus_skew_rpt

write_debug_probes -force $ltx_out
write_bitstream -force $bit_out
puts "GUARDED_BITSTREAM=$bit_out"
puts "GUARDED_LTX=$ltx_out"

close_design
close_project
