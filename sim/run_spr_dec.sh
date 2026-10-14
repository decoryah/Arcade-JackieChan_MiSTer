#!/bin/bash
# Frozen-state bench of pass 1 of the banded sprite renderer (rtl/jchan_spr_dec.sv + tb_jchan_spr_dec.cpp), run inside WSL:
#   mister/sim/run_spr_dec.sh <cases.bin> <out.bin> [+lat=n +rnd=seed +depth=n +wr=n]
# Builds once in $HOME/build_jchan/spr_dec (BUILD_DIR overrides it; NOBUILD=1 reuses the build).
set -e
cd "$(dirname "$0")"
CASES="$1"; OUT="$2"; shift 2 || true
[ -f "$CASES" ] && [ -n "$OUT" ] || { echo "usage: $0 <cases.bin> <out.bin> [+lat=n] [+rnd=seed] [+depth=n] [+wr=n]" >&2; exit 2; }
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_jchan/spr_dec}"
mkdir -p "$B"
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -CFLAGS "-O3 -march=native" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -GPINGPONG=${PINGPONG:-0} --top-module jchan_spr_dec -Mdir "$B/obj" ../rtl/jchan_spr_dec.sv tb_jchan_spr_dec.cpp > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
"$B/obj/Vjchan_spr_dec" "$CASES" "$OUT" "$@"
