open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target

set dev [lindex [get_hw_devices] 0]
if {$dev eq ""} {
    error "No hardware devices found"
}

current_hw_device $dev
refresh_hw_device $dev

puts "CONFIG_STATUS_DEVICE=$dev"
foreach prop [lsort [list_property $dev]] {
    if {[regexp -nocase {BOOT|CONFIG|DONE|INIT|PROGRAM|MODE|STATUS} $prop]} {
        if {![catch {get_property $prop $dev} value]} {
            puts "$prop=$value"
        }
    }
}

close_hw_target
close_hw_manager
