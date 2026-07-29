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
set impl_run  [get_runs impl_1]

# V19 bring-up edits must not reuse stale synthesized checkpoints.
set_property AUTO_INCREMENTAL_CHECKPOINT 0 $synth_run
set_property INCREMENTAL_CHECKPOINT "" $synth_run
set_property AUTO_INCREMENTAL_CHECKPOINT 0 $impl_run
set_property INCREMENTAL_CHECKPOINT "" $impl_run

reset_run synth_1
launch_runs synth_1 -jobs 12
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
puts "synth_1 status: $synth_status"
if {![string match "*Complete*" $synth_status]} {
    error "synth_1 failed: $synth_status"
}

reset_run impl_1
launch_runs impl_1 -to_step route_design -jobs 12
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
puts "impl_1 status: $impl_status"
if {![string match "*route_design Complete*" $impl_status]} {
    error "impl_1 failed: $impl_status"
}

open_run impl_1
set impl_dir [get_property DIRECTORY [get_runs impl_1]]
set top [get_property TOP [get_filesets sources_1]]
set timing_rpt [file join $impl_dir "${top}_timing_summary_routed.rpt"]
set bus_skew_rpt [file join $impl_dir "${top}_bus_skew_routed.rpt"]
report_timing_summary -max_paths 10 -routable_nets -report_unconstrained \
    -file $timing_rpt -warn_on_violation
report_bus_skew -file $bus_skew_rpt
assert_nonnegative_timing $timing_rpt
assert_bus_skew_clean $bus_skew_rpt
close_design

launch_runs impl_1 -to_step write_bitstream -jobs 12
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
puts "impl_1 status: $impl_status"
if {![string match "*write_bitstream Complete*" $impl_status]} {
    error "impl_1 bitstream failed: $impl_status"
}

close_project
