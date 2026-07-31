# Is hd_clk running?  hw_ila_2 (dbg_ila_1) is clocked by hd_clk: if it can be
# armed with an immediate trigger and its data uploads, that clock is alive.
set root [file normalize [file join [file dirname [info script]] ..]]
set ltxfile [file join $root EO_Panorama_V19_M1.runs impl_1 KintexTop_EO_IR_HD_SDI_panorama_base.ltx]

open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE $ltxfile $dev
refresh_hw_device $dev
after 2000

foreach ila [get_hw_ilas -of_objects $dev] {
    puts "=== $ila : [llength [get_hw_probes -of_objects $ila]] probes ==="
    set_property CONTROL.TRIGGER_POSITION 0 $ila
    if {[catch {
        reset_hw_ila $ila
        run_hw_ila $ila -trigger_now
        wait_on_hw_ila -timeout 1 $ila
        upload_hw_ila_data $ila
    } msg]} {
        puts "RESULT $ila : CLOCK STOPPED or no capture ($msg)"
    } else {
        puts "RESULT $ila : CLOCK RUNNING (armed, triggered and uploaded)"
    }
}
close_hw_target
close_hw_manager
