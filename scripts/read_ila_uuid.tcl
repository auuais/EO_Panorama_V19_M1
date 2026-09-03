# Which bitstream is actually in the FPGA?  READ ONLY - programs nothing.
#
# Every build stamps its ILA cores with a fresh UUID, and the .ltx archived
# next to each .bit records it.  Matching the UUID read back over JTAG against
# the archived .ltx files identifies the running image exactly, which guessing
# from the picture cannot do.
#
#   vivado -mode batch -source scripts/read_ila_uuid.tcl
open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -quiet $dev
puts "DEVICE: $dev"
foreach c [get_hw_ilas -quiet -of_objects $dev] {
    puts "ILA: [get_property NAME $c]  UUID=[get_property CORE_UUID $c] DEPTH=[get_property CONTROL.DATA_DEPTH $c]"
}
close_hw_target
close_hw_manager
