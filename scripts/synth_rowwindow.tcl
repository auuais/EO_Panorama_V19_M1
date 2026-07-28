set project_root [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $project_root EO_IR_HD_SDI_Stabilization_RowWindow.xpr]
set_param general.maxThreads 8
reset_run synth_1
launch_runs synth_1 -jobs 12
wait_on_run synth_1
set status [get_property STATUS [get_runs synth_1]]
puts "synth_1 status: $status"
if {![string match "*Complete*" $status]} {
    error "synth_1 failed: $status"
}
close_project
