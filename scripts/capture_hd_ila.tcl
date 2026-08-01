# Capture the hd_clk-domain ILA (dbg_ila_1 / hw_ila_2).
# probe0 = eo_fpga_trigger_common -- the master exposure trigger, derived from
# camera 0's STROBE_OUT0.  If that never pulses, the global content-frame epoch
# never advances and every camera discards every raster.
#   vivado -mode batch -source scripts/capture_hd_ila.tcl -tclargs <label>
set root [file normalize [file join [file dirname [info script]] ..]]
set label "hd"
if {[llength $argv] > 0} { set label [lindex $argv 0] }
set ltxfile [file join $root EO_Panorama_V19_M1.runs impl_1 KintexTop_EO_IR_HD_SDI_panorama_base.ltx]
set stamp [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
set outcsv [file join $root captures usb0_v19 "ila_hd_${label}_$stamp.csv"]
file mkdir [file dirname $outcsv]

open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE $ltxfile $dev
refresh_hw_device $dev
after 2000

# The hd_clk ILA is the one WITHOUT a 'running' probe.
set ila ""
foreach cand [get_hw_ilas -of_objects $dev] {
    if {[llength [get_hw_probes -of_objects $cand -filter {NAME =~ "*running"} -quiet]] == 0} {
        set ila $cand
        break
    }
}
if {$ila eq ""} { puts "ERROR: hd_clk ILA not found"; close_hw_target; close_hw_manager; exit 1 }
puts "ILA=$ila"

set_property CONTROL.TRIGGER_POSITION 0 $ila
reset_hw_ila $ila
run_hw_ila $ila -trigger_now
wait_on_hw_ila -timeout 10 $ila
upload_hw_ila_data $ila
write_hw_ila_data -csv_file -force $outcsv [get_hw_ila_data -of_objects $ila]
puts "CSV=$outcsv"
close_hw_target
close_hw_manager
