set root [file normalize [file join [file dirname [info script]] ..]]
set ltxfile [file join $root EO_Panorama_V19_M1.runs impl_1 KintexTop_EO_IR_HD_SDI_panorama_base.ltx]
set outdir [file join $root captures usb0_v19]
file mkdir $outdir

if {![info exists ::env(CAPTURE_COUNT)]} {
    set capture_count 6
} else {
    set capture_count $::env(CAPTURE_COUNT)
}

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
    if {[llength [get_hw_probes -of_objects $cand -filter {NAME =~ "*v19_dbg_rows_word2_strobe*"} -quiet]] > 0} {
        set ila $cand
        break
    }
}
if {$ila eq ""} { error "Could not find ILA containing v19_dbg_rows_word2_strobe" }

set trig [get_hw_probes -of_objects $ila -filter {NAME =~ "*v19_dbg_rows_word2_strobe*"} -quiet]
puts "ILA=$ila TRIGGER=$trig"

# v19_dbg_rows_word2_strobe bit layout in PanoramaBase_DdrBlackFrame.v:
# [63:58] strobe period high bits, [57] synchronized level,
# [56] one-cycle rising-edge pulse, [55] seen flag, [54:51] edge counter.
set cmp [format "eq64'b%s1%s" [string repeat x 7] [string repeat x 56]]
set_property CONTROL.TRIGGER_POSITION 512 $ila
set_property TRIGGER_COMPARE_VALUE $cmp $trig

for {set i 0} {$i < $capture_count} {incr i} {
    puts "CAPTURE_INDEX=$i"
    run_hw_ila $ila
    wait_on_hw_ila -timeout 40 $ila
    upload_hw_ila_data $ila
    set outcsv [file join $outdir [format "ila_strobe_edge_%02d.csv" $i]]
    write_hw_ila_data -csv_file -force $outcsv [get_hw_ila_data -of_objects $ila]
    puts "CSV=$outcsv"
}

close_hw_target
close_hw_manager
