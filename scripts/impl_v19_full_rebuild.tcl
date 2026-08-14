set project_root [file normalize [file join [file dirname [info script]] ..]]
source [file join $project_root scripts v19_fileset.tcl]

set place_directive "Default"
set place_directive_set 0
set reuse_synth 0
set qspi_no_ila 0
foreach arg $argv {
    if {$arg eq ""} {
        continue
    } elseif {$arg eq "reuse-synth"} {
        set reuse_synth 1
    } elseif {$arg eq "noila" || $arg eq "qspi-no-ila"} {
        set qspi_no_ila 1
    } elseif {!$place_directive_set} {
        set place_directive $arg
        set place_directive_set 1
    } else {
        error "Unexpected argument '$arg'; expected one place directive plus optional reuse-synth/noila"
    }
}

# Progress reporting.
#
# Only synthesis shows up in an open Vivado GUI, because it is the one stage
# launched as a project run (launch_runs synth_1).  Implementation runs here as
# explicit opt/place/phys_opt/route commands in an in-memory project, which the
# GUI's Design Runs window knows nothing about.  That is deliberate and must
# stay that way: a project impl run can continue into its generated
# write_bitstream step before the Tcl timing guard below regains control, which
# is exactly how a bitstream with violated MIG paths would escape.
#
# So report progress explicitly instead.  Each phase appends a timestamped line
# to build_progress.txt, which is tiny and safe to tail from anywhere:
#
#     tail -f build_progress.txt          (or: python scripts/build_watch.py)
set v19_progress_file [file join $project_root build_progress.txt]
set v19_phase_start [clock seconds]
proc v19_phase {msg} {
    global v19_progress_file v19_phase_start
    set now [clock seconds]
    set line [format "%s  %6ds  %s" \
                  [clock format $now -format "%H:%M:%S"] \
                  [expr {$now - $v19_phase_start}] $msg]
    puts "PHASE: $line"
    flush stdout
    if {![catch {open $v19_progress_file a} fh]} {
        puts $fh $line
        close $fh
    }
}
if {![catch {open $v19_progress_file w} fh]} {
    puts $fh "=== build started [clock format [clock seconds]] ==="
    close $fh
}
open_project [file join $project_root EO_Panorama_V19_M1.xpr]
set project_default_defines [get_property verilog_define [get_filesets sources_1]]
while {[set define_idx [lsearch -exact $project_default_defines QSPI_NO_ILA]] >= 0} {
    set project_default_defines [lreplace $project_default_defines $define_idx $define_idx]
}
set current_defines $project_default_defines
set define_idx [lsearch -exact $current_defines QSPI_NO_ILA]
if {$qspi_no_ila} {
    if {$define_idx < 0} {
        lappend current_defines QSPI_NO_ILA
    }
    puts "QSPI_NO_ILA build enabled: RTL ILA instances and ILA IPs are excluded"
} else {
    if {$define_idx >= 0} {
        set current_defines [lreplace $current_defines $define_idx $define_idx]
    }
}
set_property verilog_define $current_defines [get_filesets sources_1]

# Never trust the .xpr's current fileset: batch runs have dropped source
# entries on close_project, which fails the next elaboration.
v19_refresh_fileset $project_root $qspi_no_ila
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

# Optional argument "reuse-synth" re-implements from the existing synthesis
# checkpoint.  Only valid when the RTL has not changed since that checkpoint --
# use it to retry placement after a MIG-internal skew failure, never after a
# source edit.
if {$reuse_synth} {
    puts "reusing existing synth_1 checkpoint (RTL assumed unchanged)"
} else {
    v19_phase "synthesis started (visible in the GUI Design Runs window)"
    reset_run synth_1
    launch_runs synth_1 -jobs 12
    wait_on_run synth_1
    v19_phase "synthesis complete"
}
set synth_status [get_property STATUS [get_runs synth_1]]
puts "synth_1 status: $synth_status"
# In reuse-synth mode the run reports "Out-of-date" even when the checkpoint on
# disk is exactly the one we want: Vivado compares source timestamps and
# v19_refresh_fileset re-adds every file on entry.  The checkpoint's existence
# is verified below, which is the real precondition, so only assert a clean
# Complete when we actually ran synthesis.
if {!$reuse_synth && ![string match "*Complete*" $synth_status]} {
    error "synth_1 failed: $synth_status"
}

set top [get_property TOP [get_filesets sources_1]]
set part [get_property PART [current_project]]
set synth_dir [get_property DIRECTORY $synth_run]
set synth_dcp [file join $synth_dir "${top}.dcp"]
if {![file exists $synth_dcp]} {
    error "Synthesized checkpoint not found: $synth_dcp"
}

set ip_files [list [file join $project_root ip ddr4_sub64 ddr4_sub64.xci]]
if {!$qspi_no_ila} {
    set ip_files [concat [list \
        [file join $project_root ip dbg_ila_1 dbg_ila_1.xci] \
        [file join $project_root ip dbg_ila_0 dbg_ila_0.xci] \
    ] $ip_files]
}
set xdc_files [list \
    [file join $project_root constraints camera_base.xdc] \
    [file join $project_root constraints ddr4_sub64_firstpass.xdc] \
]

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

# Recreate the project-generated implementation link stage explicitly.  A raw
# open_checkpoint sees the synthesized top DCP but leaves the ILA/MIG IP as
# black boxes; the generated Vivado run resolves those cells by reading the
# IP .xci files before link_design.
if {$qspi_no_ila} {
    v19_phase "restoring debug-capable project fileset"
    set_property verilog_define $project_default_defines [get_filesets sources_1]
    v19_refresh_fileset $project_root 0
}
close_project
create_project -in_memory -part $part
set_property design_mode GateLvl [current_fileset]
set_param project.singleFileAddWarning.threshold 0
set_property webtalk.parent_dir [file join $project_root EO_Panorama_V19_M1.cache wt] [current_project]
set_property parent.project_path [file join $project_root EO_Panorama_V19_M1.xpr] [current_project]
set_property ip_output_repo [file join $project_root EO_Panorama_V19_M1.cache ip] [current_project]
set_property ip_cache_permissions {read write} [current_project]
set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
add_files -quiet $synth_dcp
foreach ip_file $ip_files {
    read_ip -quiet $ip_file
}
foreach xdc_file $xdc_files {
    read_xdc $xdc_file
}
v19_phase "link_design"
link_design -top $top -part $part

# Placement directive, overridable from the command line:
#   vivado ... -source scripts/impl_v19_full_rebuild.tcl -tclargs <place_directive> ?reuse-synth? ?noila?
# The DDR4 PHY carries MIG-internal Min Skew checks between RXTX_BITSLICE pins
# that are sensitive to how the rest of the design places around them.  An
# unrelated logic edit can push one of those negative (seen 2026-08-02:
# WPWS -0.269 on xiphy_rxtx_bitslice/D[2] with setup and hold both clean), and
# re-running an identical build is pointless because Vivado is deterministic.
# Changing the directive re-places the design without touching logic.
puts "place_design directive: $place_directive"

v19_phase "opt_design"
opt_design
write_checkpoint -force $opt_dcp

if {$place_directive eq "Default"} {
    place_design
} else {
    place_design -directive $place_directive
}
write_checkpoint -force $placed_dcp
v19_phase "place_design complete"

v19_phase "phys_opt_design"
phys_opt_design
write_checkpoint -force $physopt_dcp

v19_phase "route_design (longest stage)"
route_design
write_checkpoint -force $routed_dcp
v19_phase "route_design complete"
report_route_status -file $route_rpt
report_timing_summary -max_paths 10 -routable_nets -report_unconstrained \
    -file $timing_rpt -warn_on_violation
report_bus_skew -file $bus_skew_rpt
v19_phase "timing reports written"
assert_nonnegative_timing $timing_rpt
assert_bus_skew_clean $bus_skew_rpt

if {$qspi_no_ila} {
    v19_phase "no-ILA build: skipping debug probe file"
} else {
    write_debug_probes -force $ltx_out
}
v19_phase "timing PASSED - writing bitstream"
write_bitstream -force $bit_out
v19_phase "BITSTREAM DONE"
puts "GUARDED_BITSTREAM=$bit_out"
if {$qspi_no_ila} {
    puts "GUARDED_LTX=disabled_no_ila"
} else {
    puts "GUARDED_LTX=$ltx_out"
}

close_design
close_project
