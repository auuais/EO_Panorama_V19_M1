# What is true at the moment the output framebuffer is allowed to start a copy?
#
# A copy may only begin when copy_armed is set, and copy_armed is set by
# frame_edge -- the display frame edge, 30 Hz.  So every published frame is
# decided at a frame_edge, and a frame is lost whenever the edge arrives and
# copy_start_accept cannot fire.  Two things can prevent it, and they call for
# opposite fixes:
#
#   no lease (v19_replay_banks_ready = 0)  -> the six-camera set was not ready:
#                                             the problem is upstream, in
#                                             capture and the frame-set manager
#   copy_active = 1                        -> the previous copy is still running:
#                                             the problem is the copy itself
#
# Triggering ON frame_edge and reading the other signals at that instant
# samples the decision directly, instead of inferring it from occupancy.  Each
# capture catches the next edge, so N captures are N consecutive-ish decisions.
#
#   vivado -mode batch -source scripts/capture_at_frame_edge.tcl -tclargs <label> <n>
set root [file normalize [file join [file dirname [info script]] ..]]
set label "edge"
set n 120
if {[llength $argv] > 0} { set label [lindex $argv 0] }
if {[llength $argv] > 1} { set n [lindex $argv 1] }

set ltxfile [file join $root EO_Panorama_V19_M1.runs impl_1 KintexTop_EO_IR_HD_SDI_panorama_base.ltx]
if {[info exists ::env(V19_LTX)] && $::env(V19_LTX) ne ""} {
    set ltxfile [file normalize $::env(V19_LTX)]
}
set stamp [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set outdir [file join $root captures usb0_v19 "edge_${label}_$stamp"]
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

set pe [lindex [get_hw_probes -of_objects $ila -filter {NAME =~ "*/frame_edge"}] 0]
set_property TRIGGER_COMPARE_VALUE eq1'b1 $pe
set_property CONTROL.TRIGGER_POSITION 1024 $ila

set fired 0
for {set i 0} {$i < $n} {incr i} {
    reset_hw_ila $ila
    run_hw_ila $ila
    if {[catch {wait_on_hw_ila -timeout 5 $ila}]} { continue }
    incr fired
    upload_hw_ila_data $ila
    write_hw_ila_data -csv_file -force \
        [file join $outdir [format "e%04d.csv" $i]] \
        [get_hw_ila_data -of_objects $ila]
}
puts "OUTDIR=$outdir FIRED=$fired"
close_hw_target
close_hw_manager
