set project_root [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $project_root EO_IR_HD_SDI_Stabilization_RowWindow.xpr]
set_param general.maxThreads 8
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 12
wait_on_run impl_1
set status [get_property STATUS [get_runs impl_1]]
puts "impl_1 status: $status"
if {![string match "*write_bitstream Complete*" $status]} {
    error "impl_1 did not produce a bitstream: $status"
}
close_project
