# EO camera frame rate, measured electrically from the published descriptor
# epochs.  READ ONLY.
#
# Why this and not the optical count: the optical measurement sees the OUTPUT,
# so a 15 fps reading there is equally consistent with a 15 fps camera and with
# a 30 fps camera whose frames are published every other time.  v19_capN_desc_epoch
# increments once per frame the camera actually writes into DDR, upstream of
# every output-side mechanism, so its slope is the camera rate and nothing else.
#
# Sampled repeatedly in one session with a wall clock alongside; 8 bits wrap
# every 256 frames, so keep the interval well under 8 s at 30 fps.
#
#   vivado -mode batch -source scripts/measure_cam_epoch_rate.tcl -tclargs <n> <ms>
set root [file normalize [file join [file dirname [info script]] ..]]
set n 12
set gap 700
if {[llength $argv] > 0} { set n [lindex $argv 0] }
if {[llength $argv] > 1} { set gap [lindex $argv 1] }

set ltxfile [file join $root EO_Panorama_V19_M1.runs impl_1 KintexTop_EO_IR_HD_SDI_panorama_base.ltx]
if {[info exists ::env(V19_LTX)] && $::env(V19_LTX) ne ""} {
    set ltxfile [file normalize $::env(V19_LTX)]
}

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

set stamp [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set outdir [file join $root captures usb0_v19 "epoch_$stamp"]
file mkdir $outdir

for {set i 0} {$i < $n} {incr i} {
    run_hw_ila -trigger_now $ila
    wait_on_hw_ila -timeout 10 $ila
    set t [clock milliseconds]
    upload_hw_ila_data $ila
    set f [file join $outdir [format "e%03d.csv" $i]]
    write_hw_ila_data -csv_file -force $f [get_hw_ila_data -of_objects $ila]
    puts "EPOCH $i $t $f"
    after $gap
}
close_hw_target
close_hw_manager
