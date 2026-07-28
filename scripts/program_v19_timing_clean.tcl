set project_root [file normalize [file join [file dirname [info script]] ..]]
set bitfile [file join $project_root timing_trials v19_route_AggressiveExplore.bit]
set ltxfile [file join $project_root timing_trials v19_route_AggressiveExplore.ltx]

if {![file exists $bitfile]} { error "Bitstream not found: $bitfile" }
if {![file exists $ltxfile]} { error "LTX not found: $ltxfile" }

open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
puts "SERVERS=[get_hw_servers]"
puts "TARGETS=[get_hw_targets *]"
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device $dev
set_property PROGRAM.FILE $bitfile $dev
set_property PROBES.FILE  $ltxfile $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "PROGRAMMED device=$dev bit=$bitfile ltx=$ltxfile"
close_hw_target
close_hw_manager
