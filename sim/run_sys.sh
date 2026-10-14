#!/bin/bash
# CPU-side system bench (tb_jchan_sys_top.sv + tb_jchan_sys.cpp: 2 x fx68k + board + toybox, real program ROMs), run inside WSL:
#   mister/sim/run_sys.sh +MAINROM=.. +SUBROM=.. +MCUDATA=.. +FRAMES=n +DUMPS=a,b,c +DUMPPFX=<prefix> [+LAT=n +RND=seed +TRACE=file ...]
# Builds once in $HOME/build_jchan/sys (BUILD_DIR overrides; NOBUILD=1 reuses the build).  CLK_HZ / CPU_DIV: the machine clock of the bench
# (default the real 96 MHz / 6); SIM_GATE=1 (default) gives the CPUs a gated clock so only the clocks with a phase enable are evaluated there
# (same behaviour, about 3x faster; SIM_GATE=0 is the plain enable form that is synthesised).
set -e
cd "$(dirname "$0")"
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_jchan/sys}"; mkdir -p "$B"
M=../modules/cpu-fx68k
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -CFLAGS "-O3 -march=native" -MAKEFLAGS "OPT_FAST=-O3 OPT_SLOW=-O1" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -GCLK_HZ=${CLK_HZ:-96000000} -GCPU_DIV=${CPU_DIV:-6} -GSIM_GATE=${SIM_GATE:-1} -I../rtl \
    --top-module tb_jchan_sys_top -Mdir "$B/obj" \
    $M/fx68kAlu.sv $M/uaddrPla.sv $M/fx68k.sv \
    ../rtl/jchan_ram.sv ../rtl/jchan_snapram.sv ../rtl/jchan_cen.sv ../rtl/jchan_toybox.sv ../rtl/jchan_m68k.sv ../rtl/jchan_board.sv ../rtl/jchan_sys.sv \
    tb_jchan_sys_top.sv tb_jchan_sys.cpp > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
cp $M/microrom.mem $M/nanorom.mem "$B/"
cd "$B"
./obj/Vtb_jchan_sys_top "$@"
