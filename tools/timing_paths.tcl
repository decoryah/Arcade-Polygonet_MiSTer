# Lists every failing setup path on the 96 MHz system clock, worst first, after a full
# compile: quartus_sta -t tools/timing_paths.tcl   (from the project directory)
# Output: output_files/timing_paths.txt as "slack from -> to". Set SKIP to a node pattern
# to leave a block out (e.g. "*dsp56156:dsp*" to see what else fails behind the DSP core).
set SKIP ""
project_open Polygonet -revision Polygonet
create_timing_netlist
read_sdc
update_timing_netlist
set clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set paths [get_timing_paths -setup -to_clock $clk -npaths 50000 -nworst 1]
set fh [open "output_files/timing_paths.txt" w]
foreach_in_collection p $paths {
  set s [get_path_info $p -slack]
  if {$s >= 0} break
  set fn [get_node_info -name [get_path_info $p -from]]
  set tn [get_node_info -name [get_path_info $p -to]]
  if {$SKIP ne "" && ([string match $SKIP $fn] || [string match $SKIP $tn])} continue
  puts $fh [format "%7.3f %s -> %s" $s $fn $tn]
}
close $fh
delete_timing_netlist
project_close
