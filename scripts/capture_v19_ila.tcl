set root [file normalize [file join [file dirname [info script]] ..]]
set ltxfile [file join $root EO_Panorama_V19_M1.runs impl_1 KintexTop_EO_IR_HD_SDI_panorama_base.ltx]
set outcsv [file join $root captures usb0_v19 ila_ddr.csv]
file mkdir [file dirname $outcsv]
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE $ltxfile $dev
refresh_hw_device $dev
after 3000
refresh_hw_device $dev
set ila ""
foreach cand [get_hw_ilas -of_objects $dev] {
    if {[llength [get_hw_probes -of_objects $cand -filter {NAME =~ "*copy_active"} -quiet]] > 0} {
        set ila $cand
        break
    }
}
set trig [get_hw_probes -of_objects $ila -filter {NAME =~ "*frame_edge"} -quiet]
puts "ILA=$ila TRIGGER=$trig"
if {[llength $trig] == 0} { error "app_rdy probe not found" }
set_property CONTROL.TRIGGER_POSITION 256 $ila
set_property TRIGGER_COMPARE_VALUE eq1'b1 $trig
run_hw_ila $ila
wait_on_hw_ila -timeout 20 $ila
upload_hw_ila_data $ila
set data [get_hw_ila_data -of_objects $ila]
write_hw_ila_data -csv_file -force $outcsv $data
puts "CSV=$outcsv"
close_hw_target
close_hw_manager
