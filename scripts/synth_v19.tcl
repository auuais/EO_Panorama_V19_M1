set project_root [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $project_root EO_Panorama_V19_M1.xpr]
set_param general.maxThreads 8
set synth_run [get_runs synth_1]
# V19 bring-up must be a real source rebuild.  Vivado's auto-incremental
# synthesis can legally reuse old hierarchical variants, which hides small RTL
# debug/bring-up edits from the routed netlist and ILA.  Disable it explicitly
# for every batch run.
set_property AUTO_INCREMENTAL_CHECKPOINT 0 $synth_run
set_property INCREMENTAL_CHECKPOINT "" $synth_run
reset_run synth_1
launch_runs synth_1 -jobs 12
wait_on_run synth_1
set status [get_property STATUS [get_runs synth_1]]
puts "synth_1 status: $status"
if {![string match "*Complete*" $status]} { error "synth_1 failed: $status" }
close_project
