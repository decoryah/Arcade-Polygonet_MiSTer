project_open dsp56156_top
create_timing_netlist -model slow -temperature 85 -voltage 1100
read_sdc
update_timing_netlist
file delete output/detail2.txt
foreach t {state* p.sp* p.l1v* lat_pa*} {
  report_timing -setup -npaths 1 -detail full_path -to [get_registers $t] -file output/detail2.txt -append
}
delete_timing_netlist
project_close
