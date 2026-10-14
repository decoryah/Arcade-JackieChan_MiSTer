#!/bin/bash
# Unit bench of jchan_snapram (follow / freeze display copy), run inside WSL:  mister/sim/run_snapram.sh [+PHASES=n] [+SEED=n] [+FOLLOW=clocks]
set -e
cd "$(dirname "$0")"
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_jchan/snapram}"; mkdir -p "$B"
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 4 -O2 --x-assign fast --x-initial fast -CFLAGS "-O2" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -I../rtl \
    --top-module tb_jchan_snapram_top -Mdir "$B/obj" \
    ../rtl/jchan_ram.sv ../rtl/jchan_snapram.sv tb_jchan_snapram_top.sv tb_jchan_snapram.cpp > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
cd "$B"
./obj/Vtb_jchan_snapram_top "$@"
