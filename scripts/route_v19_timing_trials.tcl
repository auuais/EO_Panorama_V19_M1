set project_root [file normalize [file join [file dirname [info script]] ..]]
set impl_dir     [file join $project_root EO_Panorama_V19_M1.runs impl_1]
set base_dcp     [file join $impl_dir KintexTop_EO_IR_HD_SDI_panorama_base_physopt.dcp]
set out_dir      [file join $project_root timing_trials]

file mkdir $out_dir
open_project [file join $project_root EO_Panorama_V19_M1.xpr]
set_param general.maxThreads 8

set directives {
    AggressiveExplore
    HigherDelayCost
    NoTimingRelaxation
    MoreGlobalIterations
    AdvancedSkewModeling
}

set best_slack -999.0
set best_directive ""

foreach directive $directives {
    puts "=== ROUTE TRIAL: $directive ==="
    catch {close_design}
    open_checkpoint $base_dcp

    set tag [string map {" " "_"} $directive]
    set timing_rpt [file join $out_dir "v19_route_${tag}_timing_summary.rpt"]
    set route_rpt  [file join $out_dir "v19_route_${tag}_route_status.rpt"]
    set routed_dcp [file join $out_dir "v19_route_${tag}.dcp"]

    if {[catch {route_design -directive $directive -timing_summary} route_msg]} {
        puts "ROUTE_TRIAL_FAILED $directive route_design_error=$route_msg"
        catch {close_design}
        continue
    }

    report_route_status -file $route_rpt
    report_timing_summary -max_paths 10 -routable_nets -report_unconstrained -warn_on_violation -file $timing_rpt
    write_checkpoint -force $routed_dcp

    set worst_path [get_timing_paths -max_paths 1 -nworst 1 -setup]
    if {[llength $worst_path] == 0} {
        puts "ROUTE_TRIAL_FAILED $directive no_timing_path"
        catch {close_design}
        continue
    }

    set slack [get_property SLACK $worst_path]
    puts "ROUTE_TRIAL_RESULT directive=$directive setup_slack_ns=$slack"
    if {$slack > $best_slack} {
        set best_slack $slack
        set best_directive $directive
    }

    if {$slack >= 0.0} {
        set bit_file [file join $out_dir "v19_route_${tag}.bit"]
        set ltx_file [file join $out_dir "v19_route_${tag}.ltx"]
        write_debug_probes -force $ltx_file
        write_bitstream -force $bit_file
        puts "ROUTE_TRIAL_SUCCESS directive=$directive setup_slack_ns=$slack bit=$bit_file ltx=$ltx_file"
        close_project
        exit 0
    }
}

close_project
error "No route directive met timing. Best directive=$best_directive setup_slack_ns=$best_slack"
