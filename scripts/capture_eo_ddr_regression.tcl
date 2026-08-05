# Regression capture after "Serve EO single from DDR and delete the fabric
# clock mux".  That commit changed the top-level output assignment in EVERY
# mode (HD_PCLK now always comes from hd_path_clk), so the mode that was
# already confirmed working -- IR single -- has to be re-checked, not just the
# new EO path.
#
# Triggers on copy_active and dumps the whole compositor ILA window, which
# carries copy_px_valid / copy_px_data / pix_fifo_wr_en / scan_active /
# frame_edge.  A healthy pass shows the copy running and pixels moving.
#
#   vivado -mode batch -source scripts/capture_eo_ddr_regression.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
set ltxfile [file join $root EO_Panorama_V19_M1.runs impl_1 KintexTop_EO_IR_HD_SDI_panorama_base.ltx]
set outcsv [file join $root captures eo_ddr_regression ila_copy.csv]
file mkdir [file dirname $outcsv]

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
    if {[llength [get_hw_probes -of_objects $cand -filter {NAME =~ "*copy_active"} -quiet]] > 0} {
        set ila $cand
        break
    }
}
if {$ila eq ""} { error "no ILA carrying copy_active" }

set trig [get_hw_probes -of_objects $ila -filter {NAME =~ "*copy_active"} -quiet]
puts "ILA=$ila TRIGGER=$trig"
set_property CONTROL.TRIGGER_POSITION 256 $ila
set_property TRIGGER_COMPARE_VALUE eq1'b1 $trig
run_hw_ila $ila
wait_on_hw_ila -timeout 30 $ila
upload_hw_ila_data $ila
write_hw_ila_data -csv_file -force $outcsv [get_hw_ila_data -of_objects $ila]
puts "CSV=$outcsv"
close_hw_target
close_hw_manager
