set project_root [file normalize [file join [file dirname [info script]] ..]]
set project_name EO_IR_HD_SDI_Stabilization_RowWindow
set project_xpr [file join $project_root "${project_name}.xpr"]
set target_part xcku15p-ffve1517-2-i

create_project $project_name $project_root -part $target_part -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set rtl_files [lsort [concat \
    [glob -nocomplain [file join $project_root src *.v]] \
    [glob -nocomplain [file join $project_root src *.vh]] \
]]
if {![llength $rtl_files]} {
    error "No RTL files found under [file join $project_root src]"
}
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

# Use the checked-in, hardware-proven x48 MIG configuration. Do not recreate it.
# Debug ILA cores are omitted from production/QSPI builds.
foreach xci [list \
    [file join $project_root ip ddr4_sub64 ddr4_sub64.xci] \
] {
    if {![file exists $xci]} {
        error "Required IP definition is missing: $xci"
    }
    add_files -norecurse $xci
}

set_property top KintexTop_EO_IR_HD_SDI_panorama_base [current_fileset]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "Created $project_xpr"
puts "Top: KintexTop_EO_IR_HD_SDI_panorama_base"
puts "DDR IP preserved from checked-in x48 XCI"
close_project
