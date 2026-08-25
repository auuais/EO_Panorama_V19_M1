# Read DDR4 MIG calibration status over JTAG.  READ ONLY - programs nothing.
#
# Why this exists: the whole DDR back end is gated on c0_init_calib_complete
# (PanoramaBase_DdrBlackFrame.v ~3577 sets `running` only when it asserts, and
# scan_want / output_write_want / capture_write_want are all gated on
# `running`).  If calibration never completes there is no DDR traffic at all,
# so no copy ever runs and no frame is ever committed -- the picture is black.
# The HD renderer lives on hd_clk and is independent of DDR, so it keeps
# generating the raster and the SDI link still locks GREEN.
#
# "SDI green, picture black" is therefore the exact signature of a MIG that
# did not calibrate, and this reads that status directly.
#
# Works on a no-ILA image: the MIG's own debug core survives the ILA removal,
# which is what makes calibration readable without any ILA present.
#
#   vivado -mode batch -source scripts/read_mig_cal_status.tcl

open_hw_manager
connect_hw_server -url TCP:127.0.0.1:3121
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -quiet $dev

set migs [get_hw_migs -quiet]
if {[llength $migs] == 0} {
    puts "MIG_CAL: no MIG debug core visible on this device."
    puts "         Either the image has no DDR4 debug core, or the device is"
    puts "         not configured with a MIG-bearing bitstream."
} else {
    foreach mig $migs {
        puts "=============================================================="
        puts "MIG: $mig"
        puts "=============================================================="
        # The interesting ones are CAL_STATUS (overall) and the per-stage
        # results; print everything so nothing is missed on an unfamiliar
        # IP version.
        foreach prop [list_property $mig] {
            if {[catch {get_property $prop $mig} val]} { continue }
            if {$val eq ""} { continue }
            puts [format "  %-46s %s" $prop $val]
        }
    }
}

close_hw_target
close_hw_manager
