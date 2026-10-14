# quartus_sta -t sta_report.tcl : the worst setup path of every endpoint (up to 3000) in the slow 100 C / -40 C models of the fitted jchan_fit,
# and the worst hold paths; the reports are grouped by block with sta_groups.py.
project_open jchan_core -revision jchan_fit
foreach t {100 -40} {
    create_timing_netlist -model slow -temperature $t -voltage 1100
    read_sdc
    update_timing_netlist
    report_timing -setup -npaths 3000 -nworst 1 -detail summary -file "sta_setup_$t.rpt"
    report_timing -hold -npaths 20 -nworst 1 -detail summary -file "sta_hold_$t.rpt"
    delete_timing_netlist
}
project_close
