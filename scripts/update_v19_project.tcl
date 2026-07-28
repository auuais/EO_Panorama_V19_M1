set project_root [file normalize [file join [file dirname [info script]] ..]]
set project_xpr [file join $project_root EO_Panorama_V19_M1.xpr]

proc add_if_missing {path {fileset sources_1}} {
    set norm [file normalize $path]
    if {![llength [get_files -quiet $norm]]} {
        if {$fileset eq "sources_1"} { add_files -norecurse $norm } \
        else { add_files -fileset $fileset -norecurse $norm }
    }
}

open_project $project_xpr
foreach src [lsort [glob -nocomplain [file join $project_root src *.v]]] { add_if_missing $src }
foreach inc [lsort [glob -nocomplain [file join $project_root src *.vh]]] { add_if_missing $inc }
set_property include_dirs [list [file join $project_root src]] [get_filesets sources_1]
foreach sim [lsort [glob -nocomplain [file join $project_root sim *.v]]] { add_if_missing $sim sim_1 }
set_property include_dirs [list [file join $project_root src]] [get_filesets sim_1]
foreach xdc [list [file join $project_root constraints camera_base.xdc] [file join $project_root constraints ddr4_sub64_firstpass.xdc]] { add_if_missing $xdc constrs_1 }
foreach xci [list [file join $project_root ip ddr4_sub64 ddr4_sub64.xci] [file join $project_root ip dbg_ila_0 dbg_ila_0.xci] [file join $project_root ip dbg_ila_1 dbg_ila_1.xci]] {
    if {![file exists $xci]} { error "Required IP definition is missing: $xci" }
    add_if_missing $xci
}
foreach mem [list [file join $project_root assets rowruns eo_v19_render_runs.mem] [file join $project_root assets rowruns eo_v19_render_row_max_y0.mem] [file join $project_root assets rowruns eo_v19_render_row_min_y0.mem] [file join $project_root assets rowruns eo_v19_alpha_y.mem] [file join $project_root assets rowruns eo_v19_alpha_c.mem]] {
    if {![file exists $mem]} { error "Required V19 memory artifact is missing: $mem" }
    add_if_missing $mem
}
set_property top KintexTop_EO_IR_HD_SDI_panorama_base [current_fileset]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
close_project
