set root [file normalize [file join [file dirname [info script]] ..]]
set ltxfile [file join $root EO_Panorama_V19_M1.runs impl_1 KintexTop_EO_IR_HD_SDI_panorama_base.ltx]
set outdir [file join $root captures usb0_v19]
file mkdir $outdir

if {![info exists ::env(CAPTURE_COUNT)]} {
    set capture_count 6
} else {
    set capture_count $::env(CAPTURE_COUNT)
}

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
    if {[llength [get_hw_probes -of_objects $cand -filter {NAME =~ "*eo_follow_span_cycles*"} -quiet]] > 0} {
        set ila $cand
        break
    }
}
if {$ila eq ""} { error "Could not find top ILA containing eo_follow_span_cycles" }

set trig [get_hw_probes -of_objects $ila -filter {NAME =~ "*eo_follow_all_seen_pulse*"} -quiet]
puts "ILA=$ila TRIGGER=$trig"
if {[llength $trig] == 0} { error "Could not find eo_follow_all_seen_pulse probe" }

set_property CONTROL.TRIGGER_POSITION 128 $ila
set_property TRIGGER_COMPARE_VALUE eq1'b1 $trig

for {set i 0} {$i < $capture_count} {incr i} {
    puts "CAPTURE_INDEX=$i"
    run_hw_ila $ila
    wait_on_hw_ila -timeout 60 $ila
    upload_hw_ila_data $ila
    set outcsv [file join $outdir [format "ila_fpga_trigger_followers_%02d.csv" $i]]
    write_hw_ila_data -csv_file -force $outcsv [get_hw_ila_data -of_objects $ila]
    puts "CSV=$outcsv"
}

close_hw_target
close_hw_manager
