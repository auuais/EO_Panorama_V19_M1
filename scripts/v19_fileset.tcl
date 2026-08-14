# Shared V19 fileset refresh.
#
# Vivado batch runs have been observed to rewrite EO_Panorama_V19_M1.xpr on
# close_project and drop source entries -- src/EoV19FrameSetManager.v and the
# sim/tb_*.v testbenches have both gone missing this way, which then fails the
# next project-mode synthesis at elaboration with:
#
#   ERROR: [Synth 8-439] module 'EoV19FrameSetManager' not found
#
# Every entry point that opens the project should therefore re-assert the
# fileset before launching runs, instead of trusting whatever the .xpr
# currently happens to contain.  Requires an already-open project.

proc v19_add_if_missing {path {fileset sources_1}} {
    set norm [file normalize $path]
    if {![llength [get_files -quiet $norm]]} {
        if {$fileset eq "sources_1"} { add_files -norecurse $norm } \
        else { add_files -fileset $fileset -norecurse $norm }
    }
}

proc v19_refresh_fileset {project_root {skip_debug_ip 0}} {
    foreach src [lsort [glob -nocomplain [file join $project_root src *.v]]] {
        v19_add_if_missing $src
    }
    foreach inc [lsort [glob -nocomplain [file join $project_root src *.vh]]] {
        v19_add_if_missing $inc
    }
    set_property include_dirs [list [file join $project_root src]] [get_filesets sources_1]
    foreach sim [lsort [glob -nocomplain [file join $project_root sim *.v]]] {
        v19_add_if_missing $sim sim_1
    }
    set_property include_dirs [list [file join $project_root src]] [get_filesets sim_1]
    foreach xdc [list [file join $project_root constraints camera_base.xdc] \
                      [file join $project_root constraints ddr4_sub64_firstpass.xdc]] {
        v19_add_if_missing $xdc constrs_1
    }
    set ip_defs [list [file join $project_root ip ddr4_sub64 ddr4_sub64.xci]]
    set debug_ip_defs [list [file join $project_root ip dbg_ila_0 dbg_ila_0.xci] \
                            [file join $project_root ip dbg_ila_1 dbg_ila_1.xci]]
    if {$skip_debug_ip} {
        foreach xci $debug_ip_defs {
            set existing [get_files -quiet [file normalize $xci]]
            if {[llength $existing]} {
                remove_files $existing
            }
        }
    } else {
        set ip_defs [concat $ip_defs $debug_ip_defs]
    }
    foreach xci $ip_defs {
        if {![file exists $xci]} { error "Required IP definition is missing: $xci" }
        v19_add_if_missing $xci
    }
    foreach mem [list [file join $project_root assets rowruns eo_v19_render_runs.mem] \
                      [file join $project_root assets rowruns eo_v19_render_row_max_y0.mem] \
                      [file join $project_root assets rowruns eo_v19_render_row_min_y0.mem] \
                      [file join $project_root assets rowruns eo_v19_alpha_y.mem] \
                      [file join $project_root assets rowruns eo_v19_alpha_c.mem]] {
        if {![file exists $mem]} { error "Required V19 memory artifact is missing: $mem" }
        v19_add_if_missing $mem
    }
    set_property top KintexTop_EO_IR_HD_SDI_panorama_base [current_fileset]
    update_compile_order -fileset sources_1
    update_compile_order -fileset sim_1
    v19_assert_fileset_complete $project_root
}

# Fail loudly rather than letting elaboration discover a missing module.
proc v19_assert_fileset_complete {project_root} {
    set missing [list]
    foreach src [lsort [glob -nocomplain [file join $project_root src *.v]]] {
        if {![llength [get_files -quiet [file normalize $src]]]} {
            lappend missing $src
        }
    }
    if {[llength $missing]} {
        error "Source files missing from sources_1 after refresh: $missing"
    }
    puts "v19 fileset OK: [llength [glob -nocomplain [file join $project_root src *.v]]] src/*.v present"
}
