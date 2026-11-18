project_open dsp56156_top
create_timing_netlist -model slow -temperature 85 -voltage 1100
read_sdc
update_timing_netlist
report_timing -setup -npaths 3000 -detail summary -file output/top3000.txt
delete_timing_netlist
project_close
