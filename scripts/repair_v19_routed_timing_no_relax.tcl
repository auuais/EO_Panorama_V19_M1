set root [file normalize [file join [file dirname [info script]] ..]]
set impl_dir [file join $root EO_Panorama_V19_M1.runs impl_1]
set in_dcp [file join $impl_dir KintexTop_EO_IR_HD_SDI_panorama_base_routed.dcp]
set out_dcp [file join $impl_dir KintexTop_EO_IR_HD_SDI_panorama_base_repaired.dcp]
set out_bit [file join $impl_dir KintexTop_EO_IR_HD_SDI_panorama_base_repaired.bit]
set out_ltx [file join $impl_dir debug_nets_repaired.ltx]
set after_rpt [file join $impl_dir timing_after_repair.rpt]

if {![file exists $in_dcp]} { error "Routed checkpoint not found: $in_dcp" }

set_param general.maxThreads 8
open_checkpoint $in_dcp

# Rebuild routing without timing relaxation so the router cannot sacrifice a
# hard MIG/XPHY inter-bit minimum-skew check while improving ordinary setup.
route_design -unroute
route_design -directive NoTimingRelaxation
phys_opt_design -directive AggressiveExplore
route_design -directive NoTimingRelaxation

report_timing_summary -max_paths 10 -file $after_rpt
set rpt_fd [open $after_rpt r]
set rpt_text [read $rpt_fd]
close $rpt_fd
set summary_re {^[ \t]+(-?[0-9]+\.[0-9]+)[ \t]+(-?[0-9]+\.[0-9]+)[ \t]+[0-9]+[ \t]+[0-9]+[ \t]+(-?[0-9]+\.[0-9]+)[ \t]+(-?[0-9]+\.[0-9]+)[ \t]+[0-9]+[ \t]+[0-9]+[ \t]+(-?[0-9]+\.[0-9]+)[ \t]+(-?[0-9]+\.[0-9]+)[ \t]+[0-9]+[ \t]+[0-9]+[ \t]*$}
if {![regexp -line $summary_re $rpt_text summary_line wns tns whs ths wpws tpws]} {
    error "Could not parse timing summary totals from $after_rpt"
}
puts "REPAIRED_TIMING WNS=$wns TNS=$tns WHS=$whs THS=$ths WPWS=$wpws TPWS=$tpws"
if {$wns < 0.0 || $tns < 0.0 ||
    $whs < 0.0 || $ths < 0.0 ||
    $wpws < 0.0 || $tpws < 0.0} {
    error "Post-route repair did not meet every timing check: $summary_line"
}

write_checkpoint -force $out_dcp
write_bitstream -force $out_bit
write_debug_probes -force $out_ltx
puts "REPAIRED_BIT=$out_bit"
puts "REPAIRED_LTX=$out_ltx"
close_design
