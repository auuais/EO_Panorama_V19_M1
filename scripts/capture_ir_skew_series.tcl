# Sample the IR genlock skew monitor repeatedly in ONE hardware session.
#
# A single ILA snapshot cannot tell a genlocked camera from a free-running one.
# Both look like a stable delay in one window; the difference is only visible
# over time -- a camera that missed the genlock edge and is running on its own
# oscillator drifts, so its delay WALKS between samples, while a locked camera
# holds the same delay indefinitely.
#
# So this takes N samples spaced by a settable interval and prints the decoded
# word each time.  Re-opening the hw target per sample (the obvious way) costs
# ~40 s of Vivado startup per point and makes the spacing uncontrollable, hence
# one session with `after` between captures.
#
#   vivado -mode batch -source scripts/capture_ir_skew_series.tcl \
#          -tclargs <count> <interval_ms> [tag]

set root  [file normalize [file join [file dirname [info script]] ..]]
set count    [expr {$argc > 0 ? [lindex $argv 0] : 10}]
set interval [expr {$argc > 1 ? [lindex $argv 1] : 1000}]
set tag      [expr {$argc > 2 ? [lindex $argv 2] : "series"}]

set ltxfile [file join $root EO_Panorama_V19_M1.runs impl_1 KintexTop_EO_IR_HD_SDI_panorama_base.ltx]
set outtxt  [file join $root captures frameset_state skew_$tag.txt]
file mkdir [file dirname $outtxt]
set fh [open $outtxt w]

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE $ltxfile $dev
refresh_hw_device $dev

set ila ""
foreach cand [get_hw_ilas -of_objects $dev] {
    if {[llength [get_hw_probes -of_objects $cand -filter {NAME =~ "*ir_skew_dbg*"} -quiet]] > 0} {
        set ila $cand
        break
    }
}
if {$ila eq ""} { error "no ILA carrying ir_skew_dbg" }

set_property CONTROL.TRIGGER_POSITION 0 $ila

set tmpcsv [file join $root captures frameset_state _skew_tmp.csv]

proc emit {fh line} { puts $line; puts $fh $line; flush $fh }

# Pull one probe's last captured value out of a written ILA CSV.  There is no
# get_hw_probe_value command; the CSV is the supported way to read samples.
# Layout: line 0 = column names, line 1 = radix row, line 2+ = samples.
proc csv_last {path match} {
    set f [open $path r]
    set lines [split [string trim [read $f]] "\n"]
    close $f
    set hdr [split [string trim [lindex $lines 0]] ","]
    set idx -1
    for {set i 0} {$i < [llength $hdr]} {incr i} {
        if {[string match "*$match*" [lindex $hdr $i]]} { set idx $i; break }
    }
    if {$idx < 0} { return "" }
    set row [split [string trim [lindex $lines end]] ","]
    return [string trim [lindex $row $idx]]
}

emit $fh "# n    seen   spread  maxspr  rr-delay   first to win gl  eo_present"
emit $fh "#      (units of 2^SHIFT ui_clk cycles; ~119 units per IR row)"
for {set i 0} {$i < $count} {incr i} {
    set t0 [clock milliseconds]
    run_hw_ila -trigger_now $ila
    wait_on_hw_ila -timeout 30 $ila
    upload_hw_ila_data $ila
    write_hw_ila_data -csv_file -force $tmpcsv [get_hw_ila_data -of_objects $ila]

    # Every sample in the window carries the same held word; take the last.
    set w [csv_last $tmpcsv "ir_skew_dbg"]
    if {$w eq ""} { emit $fh "  ERROR sample $i: ir_skew_dbg not in CSV"; continue }
    scan $w %llx word

    # Layout of IrGenlockSkewMonitor's dbg word, signature D.
    set sig      [expr {($word >> 60) & 0xF}]
    set seen     [expr {($word >> 54) & 0x3F}]
    set spread   [expr {($word >> 42) & 0xFFF}]
    set maxspr   [expr {($word >> 30) & 0xFFF}]
    set rr       [expr {($word >> 27) & 0x7}]
    set delay    [expr {($word >> 15) & 0xFFF}]
    set firstcam [expr {($word >> 12) & 0x7}]
    set timeouts [expr {($word >>  8) & 0xF}]
    set windows  [expr {($word >>  4) & 0xF}]
    set glphase  [expr {$word & 0xF}]

    set present [csv_last $tmpcsv "v19_cam_present"]
    if {$present eq ""} { set present "-" }

    if {$sig != 13} { emit $fh "  WARNING sample $i signature=$sig (expected D) word=$w" }
    emit $fh [format "  %-4d %06b %-7d %-7d cam%d=%-6d first=%d to=%-2d win=%-2d gl=%-2d %s" \
                  $i $seen $spread $maxspr $rr $delay $firstcam $timeouts $windows $glphase $present]

    if {$i < $count - 1} { after $interval }
}

close $fh
puts "SERIES=$outtxt"
close_hw_target
close_hw_manager
