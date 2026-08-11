set project_root [file normalize [file join [file dirname [info script]] ..]]
set top KintexTop_EO_IR_HD_SDI_panorama_base
set dcpfile [file join $project_root EO_Panorama_V19_M1.runs impl_1 "${top}_routed.dcp"]
set outdir [file join $project_root mcs boot_variants]

if {![file exists $dcpfile]} {
    error "Routed checkpoint not found: $dcpfile"
}

file mkdir $outdir
open_checkpoint $dcpfile

proc try_set_design_property {prop value} {
    if {[catch {set_property $prop $value [current_design]} msg]} {
        puts "WARNING: could not set $prop=$value: $msg"
    } else {
        puts "SET $prop=$value"
    }
}

proc try_reset_design_property {prop} {
    if {[catch {reset_property $prop [current_design]} msg]} {
        puts "WARNING: could not reset $prop: $msg"
    } else {
        puts "RESET $prop"
    }
}

proc clear_jtag_isolation_properties {} {
    try_set_design_property BITSTREAM.GENERAL.DISABLE_JTAG No
    try_set_design_property BITSTREAM.GENERAL.JTAG_SYSMON Enable
    try_reset_design_property BITSTREAM.CONFIG.TCKPIN
    try_reset_design_property BITSTREAM.CONFIG.TMSPIN
    try_reset_design_property BITSTREAM.CONFIG.TDIPIN
    try_reset_design_property BITSTREAM.CONFIG.TDOPIN
    puts "JTAG_REVERT DISABLE_JTAG=[get_property BITSTREAM.GENERAL.DISABLE_JTAG [current_design]] JTAG_SYSMON=[get_property BITSTREAM.GENERAL.JTAG_SYSMON [current_design]]"
}

proc write_qspi_variant {top outdir tag buswidth iface config_mode configrate} {
    set bitfile [file join $outdir "${top}_${tag}.bit"]
    set mcsfile [file join $outdir "${top}_${tag}.mcs"]

    try_set_design_property CONFIG_MODE $config_mode
    try_set_design_property BITSTREAM.CONFIG.SPI_BUSWIDTH $buswidth
    try_set_design_property BITSTREAM.CONFIG.CONFIGRATE $configrate
    try_set_design_property BITSTREAM.GENERAL.COMPRESS TRUE
    clear_jtag_isolation_properties
    try_set_design_property BITSTREAM.CONFIG.D00_MOSI PULLNONE
    try_set_design_property BITSTREAM.CONFIG.D01_DIN PULLNONE
    try_set_design_property BITSTREAM.CONFIG.M2PIN PULLDOWN

    write_bitstream -force $bitfile
    write_cfgmem -force -format mcs -interface $iface -size 32 \
        -loadbit "up 0x00000000 $bitfile" \
        -file $mcsfile

    puts "QSPI_VARIANT tag=$tag bit=$bitfile mcs=$mcsfile prm=[file rootname $mcsfile].prm"
}

set variants $argv
if {[llength $variants] == 0} {
    set variants [list x4]
}

foreach variant $variants {
    switch -- $variant {
        x4 {
            write_qspi_variant $top $outdir noila_qspi_x4_slow 4 SPIx4 SPIx4 10.6
        }
        x1 {
            write_qspi_variant $top $outdir noila_qspi_x1_slow 1 SPIx1 SPIx1 10.6
        }
        default {
            error "Unknown QSPI variant '$variant'; expected x4 or x1"
        }
    }
}

close_design
