#!/bin/bash
# Unit bench of the ROM memory system (jchan_mem + jchan_sdram + the 64 MB SDRAM model), run inside WSL:
#   mister/sim/run_mem.sh [+CYCLES=n] [+SEED=n] [+MODE=0x3f] [+LOAD=n] [+RDLATE=0|1] [+SDRCHK=1]
set -e
cd "$(dirname "$0")"
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_jchan/mem}"; mkdir -p "$B"
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O2 --x-assign fast --x-initial fast -CFLAGS "-O2" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -I../rtl \
    --top-module tb_jchan_mem_top -Mdir "$B/obj" \
    ../rtl/jchan_sdram.sv ../rtl/jchan_mem.sv jchan_sdram_model.sv tb_jchan_mem_top.sv tb_jchan_mem.cpp > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
cd "$B"
./obj/Vtb_jchan_mem_top "$@"
