# quartus_sta -t quartus/sta_corners.tcl   (run in mister/): the worst setup / hold path to the machine clock of the fitted whole project in the
# four models (the compile's own analysis is the slow 100 C one only);  `-t quartus/sta_corners.tcl Jchan_b` for another revision
project_open Jchan -revision [expr {[llength $quartus(args)] > 0 ? [lindex $quartus(args) 0] : "Jchan"}]
foreach {m t} {slow 100 slow -40 fast 100 fast -40} {
    create_timing_netlist -model $m -temperature $t -voltage 1100
    read_sdc
    update_timing_netlist
    set clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
    puts "=== $m $t C"
    report_timing -setup -npaths 1 -to_clock $clk -detail summary
    report_timing -hold -npaths 1 -to_clock $clk -detail summary
    delete_timing_netlist
}
project_close
