# Capture the ui_clk ILA triggered on a named probe, N times, in one session.
#
#   vivado -mode batch -source scripts/capture_on_probe.tcl \
#          -tclargs <probe-substring> <value> <label> <n> ?trigger_position?
#
# Generalises capture_at_frame_edge.tcl.  Written to answer: when
# v19_frame_done fires, what is v19_dbg_pano_y?  frame_done is supposed to be
# reachable only at pano_y == PANO_H-1 and pano_x == PANO_W-1, so any other
# value means the renderer is ending a frame somewhere it should not be able
# to.
set root [file normalize [file join [file dirname [info script]] ..]]
set probename [lindex $argv 0]
set cmpval    [lindex $argv 1]
set label     [lindex $argv 2]
set n         [lindex $argv 3]
set trigpos   16
if {[llength $argv] > 4} { set trigpos [lindex $argv 4] }

set ltxfile [file join $root EO_Panorama_V19_M1.runs impl_1 KintexTop_EO_IR_HD_SDI_panorama_base.ltx]
if {[info exists ::env(V19_LTX)] && $::env(V19_LTX) ne ""} {
    set ltxfile [file normalize $::env(V19_LTX)]
}
set stamp [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set outdir [file join $root captures usb0_v19 "trig_${label}_$stamp"]
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

set p [lindex [get_hw_probes -of_objects $ila -filter "NAME =~ \"*$probename\"" -quiet] 0]
if {$p eq ""} { puts "NOPROBE $probename"; close_hw_target; close_hw_manager; exit 1 }
puts "TRIGGER_ON=[get_property NAME $p] value=$cmpval"

# Do NOT sweep the other probes to a don't-care compare value.  Writing
# eq1'bX to every probe silently disables the trigger comparator on this core:
# the capture still reports FIRED, the TRIGGER column still appears, and the
# window contains data that does not satisfy the condition at all.  Verified
# 2026-09-03 by asking for copy_active==0 and getting a window in which it was
# 1 throughout; removing the sweep made three consecutive captures match.
# Set the one probe and nothing else, as the older working scripts did.
set_property TRIGGER_COMPARE_VALUE $cmpval $p
set_property CONTROL.TRIGGER_POSITION $trigpos $ila
puts "READBACK compare=[get_property TRIGGER_COMPARE_VALUE $p] pos=[get_property CONTROL.TRIGGER_POSITION $ila]"

set fired 0
for {set i 0} {$i < $n} {incr i} {
    reset_hw_ila $ila
    run_hw_ila $ila
    if {[catch {wait_on_hw_ila -timeout 5 $ila}]} { continue }
    incr fired
    upload_hw_ila_data $ila
    write_hw_ila_data -csv_file -force \
        [file join $outdir [format "t%04d.csv" $i]] \
        [get_hw_ila_data -of_objects $ila]
}
puts "OUTDIR=$outdir FIRED=$fired of $n"
close_hw_target
close_hw_manager
