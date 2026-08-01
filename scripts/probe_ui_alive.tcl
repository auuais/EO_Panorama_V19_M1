# Trigger-based liveness test on the ui_clk ILA.
#
# Free-running captures are only ~8.8 us at 233 MHz, far too short to conclude
# anything about bursty signals.  Arm on each signal instead and see whether the
# core ever triggers.
#   vivado -mode batch -source scripts/probe_ui_alive.tcl -tclargs [timeout_s]
set root [file normalize [file join [file dirname [info script]] ..]]
set tmo 15
if {[llength $argv] > 0} { set tmo [lindex $argv 0] }
set ltxfile [file join $root EO_Panorama_V19_M1.runs impl_1 KintexTop_EO_IR_HD_SDI_panorama_base.ltx]

open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE $ltxfile $dev
refresh_hw_device $dev
after 2000

set ila ""
foreach cand [get_hw_ilas -of_objects $dev] {
    if {[llength [get_hw_probes -of_objects $cand -filter {NAME =~ "*running"} -quiet]] > 0} {
        set ila $cand ; break
    }
}
if {$ila eq ""} { puts "ERROR: ui_clk ILA not found"; close_hw_target; close_hw_manager; exit 1 }

# write_retiring  -> a camera payload write actually retired to DDR
# copy_active     -> the compositor started an output frame
# v19_replay_banks_ready -> the frame-set manager granted a lease
foreach probename {write_retiring copy_active v19_replay_banks_ready
                   c0_ddr4_app_rd_data_valid v19_src_rd_valid} {
    set p [get_hw_probes -of_objects $ila -filter "NAME =~ \"*$probename\"" -quiet]
    if {[llength $p] == 0} { puts "RESULT $probename : probe not found" ; continue }
    set p [lindex $p 0]
    set_property CONTROL.TRIGGER_POSITION 16 $ila
    set_property TRIGGER_COMPARE_VALUE eq1'b1 $p
    reset_hw_ila $ila
    run_hw_ila $ila
    if {[catch {wait_on_hw_ila -timeout $tmo $ila} msg]} {
        puts "RESULT $probename : NEVER ASSERTS (no trigger in ${tmo}s)"
    } else {
        puts "RESULT $probename : ASSERTS"
    }
}
close_hw_target
close_hw_manager
