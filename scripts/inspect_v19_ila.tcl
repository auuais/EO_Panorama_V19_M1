open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set probes_file [file normalize [file join [file dirname [info script]] .. EO_Panorama_V19_M1.runs impl_1 KintexTop_EO_IR_HD_SDI_panorama_base.ltx]]
if {[file exists $probes_file]} { set_property PROBES.FILE $probes_file $dev }
refresh_hw_device $dev
puts "DEV=[get_property PART $dev]"
set ilas [get_hw_ilas -of_objects $dev]
puts "ILAS=[llength $ilas]"
foreach ila $ilas {
    puts "ILA=[get_property CELL_NAME $ila]"
    foreach p [get_hw_probes -of_objects $ila] {
        puts "  PROBE=[get_property NAME $p] WIDTH=[get_property WIDTH $p]"
    }
}
close_hw_target
close_hw_manager
