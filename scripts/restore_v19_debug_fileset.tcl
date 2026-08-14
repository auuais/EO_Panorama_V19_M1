set project_root [file normalize [file join [file dirname [info script]] ..]]
source [file join $project_root scripts v19_fileset.tcl]

open_project [file join $project_root EO_Panorama_V19_M1.xpr]

set defines [get_property verilog_define [get_filesets sources_1]]
while {[set define_idx [lsearch -exact $defines QSPI_NO_ILA]] >= 0} {
    set defines [lreplace $defines $define_idx $define_idx]
}
set_property verilog_define $defines [get_filesets sources_1]
v19_refresh_fileset $project_root 0

puts "RESTORED_DEBUG_FILESET verilog_define=[get_property verilog_define [get_filesets sources_1]]"
puts "RESTORED_DEBUG_FILESET dbg_ila_0=[llength [get_files -quiet [file normalize [file join $project_root ip dbg_ila_0 dbg_ila_0.xci]]]] dbg_ila_1=[llength [get_files -quiet [file normalize [file join $project_root ip dbg_ila_1 dbg_ila_1.xci]]]]"

close_project
