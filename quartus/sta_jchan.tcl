# quartus_sta -t quartus/sta_jchan.tcl   (run in mister/): the worst setup path of every endpoint of the machine clock (up to 4000) of the fitted
# whole project, slow 100 C model, and the worst hold paths; group with quartus/sta_groups.py
project_open Jchan
create_timing_netlist -model slow -temperature 100 -voltage 1100
read_sdc
update_timing_netlist
set clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
report_timing -setup -to_clock $clk -npaths 4000 -nworst 1 -detail summary -file "sta_full_setup.rpt"
report_timing -setup -to_clock $clk -npaths 5 -nworst 1 -detail full_path -file "sta_full_paths.rpt"
delete_timing_netlist
project_close
