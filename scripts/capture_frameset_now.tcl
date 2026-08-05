# Capture the frame-set / lease diagnostics in whatever state the board is in
# RIGHT NOW, with no trigger condition.
#
# Every other capture script here triggers on copy_active or copy_px_valid.
# That is useless for diagnosing a panorama that will not start, because the
# condition being waited for is exactly the one that is not happening -- the
# ILA just times out and reports nothing. -trigger_now arms and captures
# immediately instead.
#
#   vivado -mode batch -source scripts/capture_frameset_now.tcl [tag]
set root [file normalize [file join [file dirname [info script]] ..]]
set tag  [expr {$argc > 0 ? [lindex $argv 0] : "now"}]
set ltxfile [file join $root EO_Panorama_V19_M1.runs impl_1 KintexTop_EO_IR_HD_SDI_panorama_base.ltx]
set outcsv [file join $root captures frameset_state ila_$tag.csv]
file mkdir [file dirname $outcsv]

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE $ltxfile $dev
refresh_hw_device $dev
after 2000
refresh_hw_device $dev

set ila ""
foreach cand [get_hw_ilas -of_objects $dev] {
    if {[llength [get_hw_probes -of_objects $cand -filter {NAME =~ "*copy_active"} -quiet]] > 0} {
        set ila $cand
        break
    }
}
if {$ila eq ""} { error "no ILA carrying the compositor probes" }

set_property CONTROL.TRIGGER_POSITION 0 $ila
run_hw_ila -trigger_now $ila
wait_on_hw_ila -timeout 30 $ila
upload_hw_ila_data $ila
write_hw_ila_data -csv_file -force $outcsv [get_hw_ila_data -of_objects $ila]
puts "CSV=$outcsv"
close_hw_target
close_hw_manager
