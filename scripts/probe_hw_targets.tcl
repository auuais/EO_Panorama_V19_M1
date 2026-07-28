open_hw_manager
connect_hw_server
puts "SERVERS=[get_hw_servers]"
puts "TARGETS=[get_hw_targets *]"
foreach t [get_hw_targets *] {
    puts "TARGET=$t"
    catch {report_property $t} rpt
    puts $rpt
}
close_hw_manager
