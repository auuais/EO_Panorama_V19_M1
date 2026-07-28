set root [file normalize [file join [file dirname [info script]] ..]]
set ltxfile [file join $root EO_Panorama_V19_M1.runs impl_1 KintexTop_EO_IR_HD_SDI_panorama_base.ltx]
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE $ltxfile $dev
refresh_hw_device $dev
after 5000
refresh_hw_device $dev
puts "MIGS=[get_hw_migs -quiet]"
foreach m [get_hw_migs -quiet] { puts "MIG=$m"; report_property $m }
foreach ila [get_hw_ilas -of_objects $dev] {
  puts "ILA=$ila"
  foreach p [get_hw_probes -of_objects $ila] { puts "PROBE=[get_property NAME $p] WIDTH=[get_property PROBE_PORT_WIDTH $p]" }
}
close_hw_target
close_hw_manager
