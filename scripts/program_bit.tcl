# Program an arbitrary bitstream (with its matching .ltx if present).
#   vivado -mode batch -source scripts/program_bit.tcl -tclargs <path-to-.bit>
set bitfile [file normalize [lindex $argv 0]]
if {![file exists $bitfile]} { error "Bitstream not found: $bitfile" }
set ltxfile [file rootname $bitfile].ltx

open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
catch {set_property PROBES.FILE {} $dev}
catch {set_property FULL_PROBES.FILE {} $dev}
set_property PROGRAM.FILE $bitfile $dev
if {[file exists $ltxfile]} {
    set_property PROBES.FILE $ltxfile $dev
    set_property FULL_PROBES.FILE $ltxfile $dev
    puts "Using debug probes: $ltxfile"
}
program_hw_devices $dev
refresh_hw_device $dev
puts "PROGRAMMED=$bitfile"
close_hw_target
close_hw_manager
