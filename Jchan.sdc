derive_pll_clocks
derive_clock_uncertainty

# ==============================================================================
# SDRAM. The chip is clocked by the PLL's second 96 MHz output, shifted about half a period (rtl/pll/pll_0002.v); like the owner's other cores the
# pin's clock is modelled as the machine clock inverted, and the read data -- launched by the chip's edge, captured by jchan_sdram's input register
# a few edges after the READ command -- gets a two-cycle path.  The register assignments in sys/sys.tcl put the SDRAM pins' registers in the IO
# cells.  (Same constraint as metro-mister / taitol-mister / mcatadv-mister.)
# ==============================================================================
set sdram_clk_src [get_pins -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if { [get_collection_size $sdram_clk_src] == 0 } {
    set sdram_clk_src [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
}
create_generated_clock -name SDRAM_CLK -source $sdram_clk_src -divide_by 1 -phase 180 [get_ports {SDRAM_CLK}]

set sys_clk [get_clocks -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if { [get_collection_size $sys_clk] == 0 } {
    set sys_clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
}
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to $sys_clk -setup -end 2
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to $sys_clk -hold  -end 2

# ==============================================================================
# The two 68000s (fx68k).  The multicycle paths below rely on the CPU phase enables (jchan_cen: phi1 and phi2 each once per CPU_DIV = 6 clocks,
# interleaved: 3 clocks apart); with a CPU_DIV below 6 they are wrong.  (The same constraints close the core alone at 96 MHz: quartus/jchan_core.sdc.)
# ==============================================================================
# every register of the CPU changes only at one of its phase enables, so a path from one fx68k register to another has 3 clocks
set_multicycle_path -setup -end 3 -from [get_registers {*|fx68k:u_cpu|*}] -to [get_registers {*|fx68k:u_cpu|*}]
set_multicycle_path -hold  -end 2 -from [get_registers {*|fx68k:u_cpu|*}] -to [get_registers {*|fx68k:u_cpu|*}]

# the CPUs' address bus is out half a CPU clock (3 clocks) before the address strobe; everything the board does with it (decode, RAM address /
# write enable ports) is only looked at when the strobe is active (the board's RAM write enables are registered strobes, jchan_board.sv)
set_multicycle_path -setup -end 3 -from [get_registers {*|fx68k:u_cpu|excUnit:excUnit|aob[*]}]
set_multicycle_path -hold  -end 2 -from [get_registers {*|fx68k:u_cpu|excUnit:excUnit|aob[*]}]

# read data of the board's RAMs into the CPU's data input latches: the RAM address has been stable for 3+ clocks when the CPU samples
set_multicycle_path -setup -end 3 -from [get_registers {*|altsyncram*|*}] -to [get_registers {*|fx68k:u_cpu|excUnit:excUnit|dataIo:dataIo|*}]
set_multicycle_path -hold  -end 2 -from [get_registers {*|altsyncram*|*}] -to [get_registers {*|fx68k:u_cpu|excUnit:excUnit|dataIo:dataIo|*}]

# the function code outputs change with the address, half a CPU clock before the strobe (they only qualify the interrupt acknowledge)
set_multicycle_path -setup -end 3 -from [get_registers {*|fx68k:u_cpu|rFC[*]}]
set_multicycle_path -hold  -end 2 -from [get_registers {*|fx68k:u_cpu|rFC[*]}]

# ==============================================================================
# The framework's HQ2x scandoubler (sys/hq2x.sv): the blender's registers all advance on `clk_en` = ce_x4 of the scandoubler (video_mixer's `sd`),
# which is at least 3 clocks apart for this core's 13.4-clock pixels, so a path from one blender register to another has two clocks.  Only paths
# inside the blender: the blender's inputs come from registers on the same enable, but other enables (ce_out) are not covered.
# ==============================================================================
set_multicycle_path -setup -end 2 -from [get_registers {emu|arcade_video|video_mixer|sd|Hq2x|blender|*}] -to [get_registers {emu|arcade_video|video_mixer|sd|Hq2x|blender|*}]
set_multicycle_path -hold  -end 1 -from [get_registers {emu|arcade_video|video_mixer|sd|Hq2x|blender|*}] -to [get_registers {emu|arcade_video|video_mixer|sd|Hq2x|blender|*}]
