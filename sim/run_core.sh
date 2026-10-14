#!/bin/bash
# Whole-core bench (tb_jchan_core_top.sv + tb_jchan_core.cpp: jchan_core = 2 x fx68k + board + toybox + video + sound, every ROM and the decoded-sprite
# stores in the SDRAM model behind jchan_mem), run inside WSL:
#   mister/sim/run_core.sh +IMAGE=<work/rom/set.sdram.bin> +MCUDATA=<set.mcudata.bin> +FRAMES=n [+DUMPS=a,b +DUMPPFX=p] [+SNAPS=a,b +SNAPPFX=p] [+AUDIO=f]
# Builds once in $HOME/build_jchan/core (BUILD_DIR overrides; NOBUILD=1 reuses the build).  Real timing: 96 MHz / 6, CPUs on a gated clock
# (SIM_GATE=1, see rtl/jchan_m68k.sv).
set -e
cd "$(dirname "$0")"
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_jchan/core}"; mkdir -p "$B"
M=../modules/cpu-fx68k
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -CFLAGS "-O3 -march=native" -MAKEFLAGS "OPT_FAST=-O3 OPT_SLOW=-O1" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -GCLK_HZ=${CLK_HZ:-96000000} -GCPU_DIV=${CPU_DIV:-6} -GSIM_GATE=${SIM_GATE:-1} ${VFLAGS} -I../rtl \
    --top-module tb_jchan_core_top -Mdir "$B/obj" \
    $M/fx68kAlu.sv $M/uaddrPla.sv $M/fx68k.sv \
    ../rtl/jchan_ram.sv ../rtl/jchan_snapram.sv ../rtl/jchan_cen.sv ../rtl/jchan_toybox.sv ../rtl/jchan_m68k.sv ../rtl/jchan_board.sv ../rtl/jchan_sys.sv \
    ../rtl/jchan_ymz280b.sv ../rtl/jchan_audio48.sv ../rtl/jchan_spr_dec.sv ../rtl/jchan_spr_band.sv ../rtl/jchan_spr.sv \
    ../rtl/jchan_view2.sv ../rtl/jchan_mix.sv ../rtl/jchan_video.sv ../rtl/jchan_core.sv ../rtl/jchan_sdram.sv ../rtl/jchan_mem.sv \
    jchan_sdram_model.sv tb_jchan_core_top.sv tb_jchan_core.cpp > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
cp $M/microrom.mem $M/nanorom.mem "$B/"
cd "$B"
./obj/Vtb_jchan_core_top "$@"
