set project_root [file normalize [file join [file dirname [info script]] ..]]
set project_name EO_Panorama_V19_M1
set project_xpr [file join $project_root "${project_name}.xpr"]
set target_part xcku15p-ffve1517-2-i

create_project $project_name $project_root -part $target_part -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set rtl_files [lsort [concat \
    [glob -nocomplain [file join $project_root src *.v]] \
    [glob -nocomplain [file join $project_root src *.vh]] \
]]
if {![llength $rtl_files]} { error "No RTL files found under [file join $project_root src]" }
add_files -norecurse $rtl_files
set_property include_dirs [list [file join $project_root src]] [get_filesets sources_1]

set sim_files [lsort [glob -nocomplain [file join $project_root sim *.v]]]
if {[llength $sim_files]} {
    add_files -fileset sim_1 -norecurse $sim_files
    set_property include_dirs [list [file join $project_root src]] [get_filesets sim_1]
}

add_files -fileset constrs_1 -norecurse [list \
    [file join $project_root constraints camera_base.xdc] \
    [file join $project_root constraints ddr4_sub64_firstpass.xdc] \
]

# The x48 MIG is a checked-in, hardware-proven IP configuration.  Never
# regenerate it from the old x64 helper script.
foreach xci [list \
    [file join $project_root ip ddr4_sub64 ddr4_sub64.xci] \
    [file join $project_root ip dbg_ila_0 dbg_ila_0.xci] \
    [file join $project_root ip dbg_ila_1 dbg_ila_1.xci] \
] {
    if {![file exists $xci]} { error "Required IP definition is missing: $xci" }
    add_files -norecurse $xci
}

foreach mem [list \
    [file join $project_root assets rowruns eo_v19_render_runs.mem] \
    [file join $project_root assets rowruns eo_v19_render_row_max_y0.mem] \
    [file join $project_root assets rowruns eo_v19_render_row_min_y0.mem] \
    [file join $project_root assets rowruns eo_v19_alpha_y.mem] \
    [file join $project_root assets rowruns eo_v19_alpha_c.mem] \
] {
    if {![file exists $mem]} { error "Required V19 memory artifact is missing: $mem" }
    add_files -norecurse $mem
}

set_property top KintexTop_EO_IR_HD_SDI_panorama_base [current_fileset]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts "Created $project_xpr"
puts "Top: KintexTop_EO_IR_HD_SDI_panorama_base"
close_project
