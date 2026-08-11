set project_root [file normalize [file join [file dirname [info script]] ..]]
set top KintexTop_EO_IR_HD_SDI_panorama_base
set bitfile [file join $project_root EO_Panorama_V19_M1.runs impl_1 "${top}.bit"]
set outfile [file join $project_root mcs "${top}_noila_qspi.mcs"]

if {[llength $argv] > 0} {
    set outfile [file normalize [lindex $argv 0]]
}

if {![file exists $bitfile]} {
    error "Bitstream not found: $bitfile"
}

file mkdir [file dirname $outfile]

# Match the existing QSPI geometry from V19_M1_Timout.prm:
# format MCS, interface SPIX4, size 32M, start address 0x00000000.
write_cfgmem -force -format mcs -interface SPIx4 -size 32 \
    -loadbit "up 0x00000000 $bitfile" \
    -file $outfile

puts "QSPI_MCS=$outfile"
puts "QSPI_PRM=[file rootname $outfile].prm"
