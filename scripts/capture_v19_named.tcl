# Parametrised V19 ILA capture.
#
#   vivado -mode batch -source scripts/capture_v19_named.tcl -tclargs <label> [program]
#
# Triggers on `running` (the DDR backend enable) rather than copy_active, so a
# frozen pipeline -- where copy_active never asserts -- still produces a window.
# Writes captures/usb0_v19/ila_<label>_<stamp>.csv.

set root [file normalize [file join [file dirname [info script]] ..]]
set label "capture"
set do_program 0
if {[llength $argv] > 0} { set label [lindex $argv 0] }
if {[llength $argv] > 1 && [lindex $argv 1] eq "program"} { set do_program 1 }

set bitfile [file join $root EO_Panorama_V19_M1.runs impl_1 KintexTop_EO_IR_HD_SDI_panorama_base.bit]
set ltxfile [file join $root EO_Panorama_V19_M1.runs impl_1 KintexTop_EO_IR_HD_SDI_panorama_base.ltx]
# Capturing from a bitstream that is NOT the current impl_1 output is a normal
# thing to want -- comparing a build against an archived one, or reading a
# board while the next build is still writing impl_1.  V19_LTX names the probes
# file to use in that case; without it nothing changes.
if {[info exists ::env(V19_LTX)] && $::env(V19_LTX) ne ""} {
    set ltxfile [file normalize $::env(V19_LTX)]
    puts "LTX override: $ltxfile"
}
if {![file exists $ltxfile]} {
    puts "ERROR: probes file not found: $ltxfile"
    puts "       set V19_LTX to the .ltx matching the programmed bitstream"
    exit 1
}
set stamp [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set outcsv [file join $root captures usb0_v19 "ila_${label}_$stamp.csv"]
file mkdir [file dirname $outcsv]

open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev

if {$do_program} {
    if {![file exists $bitfile]} { error "Bitstream not found: $bitfile" }
    set_property PROGRAM.FILE $bitfile $dev
    set_property PROBES.FILE $ltxfile $dev
    program_hw_devices $dev
    puts "PROGRAMMED=$bitfile"
    after 3000
}

set_property PROBES.FILE $ltxfile $dev
refresh_hw_device $dev
after 3000
refresh_hw_device $dev

# Pick the DDR back-end ILA by a probe only it carries.
#
# This used to select on NAME =~ "*running", which had two problems: the
# back-end ILA has no `running` probe at all in the current build, and the
# trigger-sync ILA has `eo_trigger_free_running`, which matches.  So every
# capture silently came from the wrong core, decoded as all-zero, and read as
# "capture DEAD".
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
puts "ILA=$ila"
# Trigger on an active output copy so the window contains the traffic being
# measured rather than an inter-copy gap.
set trig [get_hw_probes -of_objects $ila -filter {NAME =~ "*/copy_active"} -quiet]
if {[llength $trig] == 0} {
    set trig [get_hw_probes -of_objects $ila -filter {NAME =~ "*/write_retiring"} -quiet]
}

set_property CONTROL.TRIGGER_POSITION 512 $ila
set_property TRIGGER_COMPARE_VALUE eq1'b1 $trig
run_hw_ila $ila
wait_on_hw_ila -timeout 20 $ila
upload_hw_ila_data $ila
write_hw_ila_data -csv_file -force $outcsv [get_hw_ila_data -of_objects $ila]
puts "CSV=$outcsv"
close_hw_target
close_hw_manager
