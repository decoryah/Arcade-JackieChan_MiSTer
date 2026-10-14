#!/bin/bash
# Frozen-state sprite chip bench (rtl/jchan_rle.sv + tb_jchan_rle.cpp), run inside WSL:
#   mister/sim/run_rle.sh <cases.bin> <crc-out.txt> [bench args: +lat=n +rnd=seed +dump=case:frame:file]
# Builds once in $HOME/build_jchan/rle (BUILD_DIR overrides it; NOBUILD=1 reuses the build).
set -e
cd "$(dirname "$0")"
CASES="$1"; OUT="$2"; shift 2 || true
[ -f "$CASES" ] && [ -n "$OUT" ] || { echo "usage: $0 <cases.bin> <crc-out.txt> [+lat=n] [+rnd=seed] [+dump=c:f:file]" >&2; exit 2; }
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_jchan/rle}"; PROF=""
if [ -n "$PROFILE" ]; then B="$B-prof"; PROF="--public-flat-rw -CFLAGS -DPROFILE"; fi
mkdir -p "$B"
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 $PROF -O3 --x-assign fast --x-initial fast -CFLAGS "-O3 -march=native" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    --top-module jchan_rle -Mdir "$B/obj" ../rtl/jchan_rle.sv tb_jchan_rle.cpp > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
"$B/obj/Vjchan_rle" "$CASES" "$OUT" "$@"
