#!/bin/bash
# Bench of the MiSTer top module (Jchan.sv, `emu`) with the framework's pll / hps_io / arcade_video replaced by emu_stubs.sv, inside WSL:
#   mister/sim/run_emu.sh +STREAM=<MRA's ROM stream> +FRAMES=n [+SNAPS=a,b +SNAPPFX=p] [+DIP=hex] [+NVM=f] [+NVMOUT=f] [+VERIFY=<sdram image>] ...
# (the stream: `py -3.8 tools/mra_build.py "mra/<title>.mra" <merged zip> <out.rom>`).  Builds once in $HOME/build_jchan/emu (BUILD_DIR overrides;
# NOBUILD=1 reuses the build).  Real timing: 96 MHz / 6; the CPUs run on a gated clock (SIM_GATE = 1, patched into a copy of jchan_core.sv, see
# rtl/jchan_m68k.sv: the results are bit-identical, the simulation is faster).
set -e
cd "$(dirname "$0")"
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_jchan/emu}"; mkdir -p "$B"
M=../modules/cpu-fx68k
if [ -z "$NOBUILD" ]; then
sed 's/parameter SIM_GATE = 0/parameter SIM_GATE = 1/' ../rtl/jchan_core.sv > "$B/jchan_core_sg.sv"
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -CFLAGS "-O3 -march=native" -MAKEFLAGS "OPT_FAST=-O3 OPT_SLOW=-O1" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    ${VFLAGS} -I../rtl -I.. \
    --top-module tb_jchan_emu_top -Mdir "$B/obj" \
    $M/fx68kAlu.sv $M/uaddrPla.sv $M/fx68k.sv \
    ../rtl/jchan_ram.sv ../rtl/jchan_snapram.sv ../rtl/jchan_cen.sv ../rtl/jchan_toybox.sv ../rtl/jchan_m68k.sv ../rtl/jchan_board.sv ../rtl/jchan_sys.sv \
    ../rtl/jchan_ymz280b.sv ../rtl/jchan_audio48.sv ../rtl/jchan_spr_dec.sv ../rtl/jchan_spr_band.sv ../rtl/jchan_spr.sv \
    ../rtl/jchan_view2.sv ../rtl/jchan_mix.sv ../rtl/jchan_video.sv "$B/jchan_core_sg.sv" ../rtl/jchan_sdram.sv ../rtl/jchan_mem.sv \
    ../rtl/jchan_standby.sv ../rtl/jchan_io.sv ../rtl/jchan_fastload.sv ../modules/crt-adjust/crt_adjust.sv ../sys/video_freak.sv ../sys/math.sv ../Jchan.sv emu_stubs.sv \
    jchan_sdram_model.sv tb_jchan_emu_top.sv tb_jchan_emu.cpp > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
cp $M/microrom.mem $M/nanorom.mem "$B/"
cd "$B"
./obj/Vtb_jchan_emu_top "$@"
