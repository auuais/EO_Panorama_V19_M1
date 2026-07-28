set project_root [file normalize [file join [file dirname [info script]] ..]]
set bitfile [file join $project_root EO_IR_HD_SDI_Stabilization_RowWindow.runs impl_1 KintexTop_EO_IR_HD_SDI_panorama_base.bit]

if {![file exists $bitfile]} {
    error "Bitstream not found: $bitfile"
}

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device $dev
set_property PROGRAM.FILE $bitfile $dev
program_hw_devices $dev
refresh_hw_device $dev
close_hw_target
close_hw_manager
