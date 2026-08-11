set project_root [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $project_root EO_Panorama_V19_M1.xpr]
set_param general.maxThreads 8
source [file join $project_root scripts v19_fileset.tcl]
v19_refresh_fileset $project_root

set ip [get_ips ddr4_sub64]
puts "DDR4 Debug_Signal before: [get_property CONFIG.Debug_Signal $ip]"
set_property CONFIG.Debug_Signal {Disable} $ip
puts "DDR4 Debug_Signal after : [get_property CONFIG.Debug_Signal $ip]"
if {[get_property CONFIG.Debug_Signal $ip] ne "Disable"} {
    error "DDR4 Debug_Signal did not take the Disable value"
}

reset_target all $ip
generate_target all $ip
export_ip_user_files -of_objects [get_files [file join $project_root ip ddr4_sub64 ddr4_sub64.xci]] \
    -no_script -sync -force -quiet
update_compile_order -fileset sources_1
puts "DDR4_DEBUG_DISABLED"
close_project
