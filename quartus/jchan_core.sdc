# jchan_core timing constraints: one 96 MHz clock (the SDRAM clock of the MiSTer system; the two 68000s run on phase enables of it).
create_clock -name clk -period 10.416 [get_ports clk]
derive_clock_uncertainty

# The multicycle paths below rely on the CPU phase enables (jchan_cen: phi1 and phi2 each once per CPU_DIV = 6 clocks, interleaved: 3 clocks
# apart).  SIM_GATE = 1 in the simulation uses the same property: the gated clock of fx68k only ticks at the enables and the results are
# bit-identical.  With a CPU_DIV below 6 these constraints are wrong.

# ---- fx68k: every register of the CPU changes only at one of its phase enables, so a path from one fx68k register to another has 3 clocks.
set_multicycle_path -setup -end 3 -from [get_registers {*|fx68k:u_cpu|*}] -to [get_registers {*|fx68k:u_cpu|*}]
set_multicycle_path -hold  -end 2 -from [get_registers {*|fx68k:u_cpu|*}] -to [get_registers {*|fx68k:u_cpu|*}]

# ---- the CPUs' address bus: the address is out half a CPU clock (3 clocks) before the address strobe; everything the board does with it
# (decode, RAM address / write enable ports) is only looked at when the strobe is active (the board's RAM write enables are registered
# strobes, jchan_board.sv).
set_multicycle_path -setup -end 3 -from [get_registers {*|fx68k:u_cpu|excUnit:excUnit|aob[*]}]
set_multicycle_path -hold  -end 2 -from [get_registers {*|fx68k:u_cpu|excUnit:excUnit|aob[*]}]

# ---- read data of the board's RAMs into the CPU's data input latches: the RAM address has been stable for 3+ clocks when the CPU samples
set_multicycle_path -setup -end 3 -from [get_registers {*|altsyncram*|*}] -to [get_registers {*|fx68k:u_cpu|excUnit:excUnit|dataIo:dataIo|*}]
set_multicycle_path -hold  -end 2 -from [get_registers {*|altsyncram*|*}] -to [get_registers {*|fx68k:u_cpu|excUnit:excUnit|dataIo:dataIo|*}]

# ---- the function code outputs change with the address, half a CPU clock before the strobe (they only qualify the interrupt acknowledge)
set_multicycle_path -setup -end 3 -from [get_registers {*|fx68k:u_cpu|rFC[*]}]
set_multicycle_path -hold  -end 2 -from [get_registers {*|fx68k:u_cpu|rFC[*]}]
