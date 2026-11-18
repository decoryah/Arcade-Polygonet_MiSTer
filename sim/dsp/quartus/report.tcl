# quartus_sta -t report.tcl : worst setup slack per corner + top paths (slow 85C)
project_open dsp56156_top
create_timing_netlist -model slow -temperature 85 -voltage 1100
read_sdc
update_timing_netlist
set s [get_clock_domain_info -setup]
foreach d $s { puts "SLOW85 setup: clock [lindex $d 0] slack [lindex $d 1] tns [lindex $d 2]" }
report_timing -setup -npaths 30 -detail summary -file output/top_paths.txt
set h [get_clock_domain_info -hold]
foreach d $h { puts "SLOW85 hold: clock [lindex $d 0] slack [lindex $d 1]" }
delete_timing_netlist
project_close
