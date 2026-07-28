set root [file normalize [file join [file dirname [info script]] ..]]
set impl_dir [file join $root EO_Panorama_V19_M1.runs impl_1]
set ltxfile [file join $impl_dir debug_nets.ltx]
set stamp [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set outcsv [file join $root captures usb0_v19 "ila_status_linecache_widthretire_$stamp.csv"]
file mkdir [file dirname $outcsv]

if {![file exists $ltxfile]} { error "LTX not found: $ltxfile" }

open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
set dev [lindex [get_hw_devices] 0]
if {$dev eq ""} { error "No hardware device found" }
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
if {$ila eq ""} {
    puts "ERROR: ILA with copy_active probe not found"
    close_hw_target
    close_hw_manager
    exit 1
}
set trig [get_hw_probes -of_objects $ila -filter {NAME =~ "*copy_active"} -quiet]
puts "ILA=$ila TRIGGER=$trig"

set_property CONTROL.TRIGGER_POSITION 512 $ila
set_property TRIGGER_COMPARE_VALUE eq1'b1 $trig
run_hw_ila $ila
wait_on_hw_ila -timeout 20 $ila
upload_hw_ila_data $ila
write_hw_ila_data -csv_file -force $outcsv [get_hw_ila_data -of_objects $ila]
puts "CSV=$outcsv"
close_hw_target
close_hw_manager
