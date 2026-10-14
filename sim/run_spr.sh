#!/bin/bash
# Frozen-state bench of one banded sprite chip (rtl/jchan_spr.sv + jchan_spr_dec.sv + jchan_spr_band.sv + tb_jchan_spr.cpp), run inside WSL:
#   mister/sim/run_spr.sh <cases.bin> <out.bin> [+lat=n +rnd=seed +depth=n +pixdiv=n +wr=n +rlat=n]
# Builds once in $HOME/build_jchan/spr (BUILD_DIR overrides it; NOBUILD=1 reuses the build).
set -e
cd "$(dirname "$0")"
CASES="$1"; OUT="$2"; shift 2 || true
[ -f "$CASES" ] && [ -n "$OUT" ] || { echo "usage: $0 <cases.bin> <out.bin> [+lat=n] [+rnd=seed] [+depth=n] [+pixdiv=n] [+wr=n] [+rlat=n]" >&2; exit 2; }
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_jchan/spr}"
mkdir -p "$B"
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -CFLAGS "-O3 -march=native" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -GPINGPONG=${PINGPONG:-0} --top-module jchan_spr -Mdir "$B/obj" ../rtl/jchan_ram.sv ../rtl/jchan_spr.sv ../rtl/jchan_spr_dec.sv ../rtl/jchan_spr_band.sv tb_jchan_spr.cpp > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
"$B/obj/Vjchan_spr" "$CASES" "$OUT" "$@"
