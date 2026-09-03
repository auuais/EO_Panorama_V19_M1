# N untriggered ILA captures in ONE Vivado session.
#
# capture_v19_untriggered.tcl takes ~25 s per capture because almost all of
# that is opening the hardware target.  One capture is an 8.8 us window on a
# 33 ms frame, so a single capture cannot see a whole loop -- every slow signal
# reads as a constant, and six of them give a six-sample estimate with a +-20%
# error that looks like a precise percentage.  Occupancy needs tens of windows,
# and that is only affordable if the target is opened once.
#
#   vivado -mode batch -source scripts/capture_v19_loop.tcl -tclargs <label> <n>
set root [file normalize [file join [file dirname [info script]] ..]]
set label "loop"
set n 40
if {[llength $argv] > 0} { set label [lindex $argv 0] }
if {[llength $argv] > 1} { set n [lindex $argv 1] }

set ltxfile [file join $root EO_Panorama_V19_M1.runs impl_1 KintexTop_EO_IR_HD_SDI_panorama_base.ltx]
if {[info exists ::env(V19_LTX)] && $::env(V19_LTX) ne ""} {
    set ltxfile [file normalize $::env(V19_LTX)]
}

set stamp [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set outdir [file join $root captures usb0_v19 "loop_${label}_$stamp"]
file mkdir $outdir

open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE $ltxfile $dev
set_property FULL_PROBES.FILE $ltxfile $dev
refresh_hw_device $dev

set ila ""
foreach cand [get_hw_ilas -of_objects $dev] {
    if {[llength [get_hw_probes -of_objects $cand -filter {NAME =~ "*/write_retiring"} -quiet]] > 0} {
        set ila $cand ; break
    }
}
if {$ila eq ""} { puts "NOILA"; close_hw_target; close_hw_manager; exit 1 }
set_property CONTROL.TRIGGER_POSITION 0 $ila

for {set i 0} {$i < $n} {incr i} {
    run_hw_ila -trigger_now $ila
    wait_on_hw_ila -timeout 10 $ila
    upload_hw_ila_data $ila
    write_hw_ila_data -csv_file -force \
        [file join $outdir [format "w%03d.csv" $i]] \
        [get_hw_ila_data -of_objects $ila]
}
puts "OUTDIR=$outdir"
close_hw_target
close_hw_manager
