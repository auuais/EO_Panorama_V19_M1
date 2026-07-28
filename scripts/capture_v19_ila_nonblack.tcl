set root [file normalize [file join [file dirname [info script]] ..]]
set ltxfile [file join $root EO_Panorama_V19_M1.runs impl_1 KintexTop_EO_IR_HD_SDI_panorama_base.ltx]
set stamp [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set outcsv [file join $root captures usb0_v19 "ila_v19_content_row51_$stamp.csv"]
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
    if {[llength [get_hw_probes -of_objects $cand -filter {NAME =~ "*copy_active"} -quiet]] > 0} { set ila $cand; break }
}
set trig [get_hw_probes -of_objects $ila -filter {NAME =~ "*v19_dbg_bus"} -quiet]
puts "ILA=$ila TRIGGER=$trig"
set_property CONTROL.TRIGGER_POSITION 512 $ila
# Trigger on an active pixel token at the first real content row.
# Current v19_dbg_bus layout:
#   bit 49 start_copy, bit 48 px_ready, bit 46 px_valid,
#   bits 44:43 state, bits 42:34 pano_y.
# Compare: start_copy=1, px_ready=1, px_valid=1, state=2'b10, pano_y=51.
# Everything else, including frame counters and x position, is don't-care.
set_property TRIGGER_COMPARE_VALUE "eq64'bxxxxxxxxxxxxxx11x1x10000110011xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" $trig
run_hw_ila $ila
wait_on_hw_ila -timeout 20 $ila
upload_hw_ila_data $ila
write_hw_ila_data -csv_file -force $outcsv [get_hw_ila_data -of_objects $ila]
puts "CSV=$outcsv"
close_hw_target
close_hw_manager
