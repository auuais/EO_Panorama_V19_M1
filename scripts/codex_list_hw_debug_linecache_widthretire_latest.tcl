set root [file normalize [file join [file dirname [info script]] ..]]
set impl_dir [file join $root EO_Panorama_V19_M1.runs impl_1]
set ltxfile [file join $impl_dir debug_nets.ltx]
if {![file exists $ltxfile]} { error "LTX not found: $ltxfile" }

open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
set dev [lindex [get_hw_devices] 0]
if {$dev eq ""} { error "No hardware device found" }
current_hw_device $dev
set_property PROBES.FILE $ltxfile $dev
refresh_hw_device $dev
after 5000
refresh_hw_device $dev
puts "MIGS=[get_hw_migs -quiet]"
foreach m [get_hw_migs -quiet] {
  puts "MIG=$m"
  report_property $m
}
foreach ila [get_hw_ilas -of_objects $dev] {
  puts "ILA=$ila"
  foreach p [get_hw_probes -of_objects $ila] {
    set width "NA"
    catch {set width [get_property PROBE_PORT_WIDTH $p]}
    puts "PROBE=[get_property NAME $p] WIDTH=$width"
  }
}
close_hw_target
close_hw_manager
