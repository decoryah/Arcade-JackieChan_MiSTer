#!/bin/bash
# YMZ280B bench (rtl/jchan_ymz280b.sv + tb_jchan_ymz.cpp), run inside WSL:
#   mister/sim/run_ymz.sh <rom.bin> <events.txt> <nsamples> <ref.i32> [lat] [seed] [maxprint]
# TICK=<clocks per sample> (default 1152, the real 96 MHz machine; a smaller value makes a long run cheaper as long as the 8 voices fit).
set -e
cd "$(dirname "$0")"
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_jchan/ymz${TICK:+_$TICK}}"; mkdir -p "$B"
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -CFLAGS "-O3 -march=native" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTH -Wno-BLKSEQ -Wno-UNOPTFLAT -Wno-PROCASSINIT \
    ${PUBLIC:+--public-flat-rw} -GTICK_CLKS=${TICK:-1152} --top-module jchan_ymz280b -Mdir "$B/obj" ../rtl/jchan_ymz280b.sv tb_jchan_ymz.cpp \
    > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
"$B/obj/Vjchan_ymz280b" "$@"
