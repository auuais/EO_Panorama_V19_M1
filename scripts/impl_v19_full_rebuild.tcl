set project_root [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $project_root EO_Panorama_V19_M1.xpr]
set_param general.maxThreads 8

set synth_run [get_runs synth_1]
set impl_run  [get_runs impl_1]

# V19 bring-up edits must not reuse stale synthesized checkpoints.
set_property AUTO_INCREMENTAL_CHECKPOINT 0 $synth_run
set_property INCREMENTAL_CHECKPOINT "" $synth_run
set_property AUTO_INCREMENTAL_CHECKPOINT 0 $impl_run
set_property INCREMENTAL_CHECKPOINT "" $impl_run

reset_run synth_1
launch_runs synth_1 -jobs 12
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
puts "synth_1 status: $synth_status"
if {![string match "*Complete*" $synth_status]} {
    error "synth_1 failed: $synth_status"
}

reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 12
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
puts "impl_1 status: $impl_status"
if {![string match "*write_bitstream Complete*" $impl_status]} {
    error "impl_1 failed: $impl_status"
}

close_project
