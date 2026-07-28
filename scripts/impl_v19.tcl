set project_root [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $project_root EO_Panorama_V19_M1.xpr]
set_param general.maxThreads 8
set impl_run [get_runs impl_1]
set_property AUTO_INCREMENTAL_CHECKPOINT 0 $impl_run
set_property INCREMENTAL_CHECKPOINT "" $impl_run
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 12
wait_on_run impl_1
set status [get_property STATUS [get_runs impl_1]]
puts "impl_1 status: $status"
if {![string match "*write_bitstream Complete*" $status]} { error "impl_1 failed: $status" }
close_project
