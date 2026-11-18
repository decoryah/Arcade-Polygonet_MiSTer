project_open dsp56156_top
create_timing_netlist -model slow -temperature 85 -voltage 1100
read_sdc
update_timing_netlist
report_timing -setup -npaths 3 -detail full_path -file output/detail.txt
foreach t {ssh* retire_cyc* b[* y0[* pc[* sp[* sr[* r[* lc[* a[* slot_q* agu1_q* x_addr* p_addr* rrv_q* q0_* q1_* alu_* cond_q* tgt_q* rd1_a* u_per|*} {
  set p [get_timing_paths -setup -npaths 1 -to [get_registers $t]]
  foreach_in_collection q $p { puts "WORST to $t: [get_path_info $q -slack] from [get_node_info -name [get_path_info $q -from]]" }
}
delete_timing_netlist
project_close
