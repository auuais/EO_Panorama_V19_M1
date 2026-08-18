# Stage A of the HD-clock rework: hand the DDR4 system clock buffer to the top
# level so the 200 MHz oscillator on AR32/AT32 can feed both the MIG and a
# 74.25 MHz HD-pixel-clock MMCM.
#
# Behaviour-neutral by design: the MIG still receives exactly the same clock,
# just through an IBUFDS we instantiate instead of one inside the IP.  Nothing
# in the video path changes in this stage.
#
# Revert with:  git checkout ip/ddr4_sub64/ddr4_sub64.xci
#               then re-run generate_target on the IP.
set project_root [file normalize [file join [file dirname [info script]] ..]]
open_project [file join $project_root EO_Panorama_V19_M1.xpr]
set_param general.maxThreads 8

set ip [get_ips ddr4_sub64]
puts "System_Clock before: [get_property CONFIG.System_Clock $ip]"
set_property CONFIG.System_Clock {No_Buffer} $ip
puts "System_Clock after : [get_property CONFIG.System_Clock $ip]"
if {[get_property CONFIG.System_Clock $ip] ne "No_Buffer"} {
    error "MIG System_Clock did not take the No_Buffer value"
}

reset_target all $ip
generate_target all $ip
puts "MIG_REGEN_DONE"
close_project
