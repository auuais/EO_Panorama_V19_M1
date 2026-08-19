# V19 ILA capture with NO trigger condition.
#
#   vivado -mode batch -source scripts/capture_v19_untriggered.tcl -tclargs <label>
#
# Why this exists alongside capture_v19_named.tcl: that script triggers on
# copy_active, which is right for looking at traffic during a copy and wrong
# for measuring how often anything happens.  A capture armed on copy_active
# cannot sample the idle half of the cycle, and it reported copy occupancy as
# 84% when unconditional sampling gave 25-40%.  The same bias applies to the
# capture writer's drop_frame: drops cluster in the part of the cycle the
# trigger selects for.
#
# So this arms with -trigger_now and takes whatever the pipeline is doing.  One
# capture is one sample; call it repeatedly for a rate.
#
# Writes captures/usb0_v19/untrig_<label>_<stamp>.csv and prints CSV=<path>.

set root [file normalize [file join [file dirname [info script]] ..]]
set label "capture"
if {[llength $argv] > 0} { set label [lindex $argv 0] }

set ltxfile [file join $root EO_Panorama_V19_M1.runs impl_1 KintexTop_EO_IR_HD_SDI_panorama_base.ltx]
if {[info exists ::env(V19_LTX)] && $::env(V19_LTX) ne ""} {
    set ltxfile [file normalize $::env(V19_LTX)]
}
if {![file exists $ltxfile]} {
    puts "ERROR: probes file not found: $ltxfile"
    exit 1
}

set stamp [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set outcsv [file join $root captures usb0_v19 "untrig_${label}_$stamp.csv"]
file mkdir [file dirname $outcsv]

open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE $ltxfile $dev
set_property FULL_PROBES.FILE $ltxfile $dev
refresh_hw_device $dev

# Pick the DDR back-end ILA by a probe only it carries.  Selecting on
# NAME =~ "*running" used to match eo_trigger_free_running on the trigger-sync
# core, so every capture came from the wrong ILA and decoded as all-zero.
set ila ""
foreach cand [get_hw_ilas -of_objects $dev] {
    if {[llength [get_hw_probes -of_objects $cand -filter {NAME =~ "*/write_retiring"} -quiet]] > 0} {
        set ila $cand
        break
    }
}
if {$ila eq ""} {
    puts "ERROR: no ILA carrying u_ddr_black_frame/write_retiring on this device"
    close_hw_target ; close_hw_manager ; exit 1
}

set_property CONTROL.TRIGGER_POSITION 0 $ila
run_hw_ila -trigger_now $ila
wait_on_hw_ila -timeout 10 $ila
upload_hw_ila_data $ila
write_hw_ila_data -csv_file -force $outcsv [get_hw_ila_data -of_objects $ila]
puts "CSV=$outcsv"
close_hw_target
close_hw_manager
