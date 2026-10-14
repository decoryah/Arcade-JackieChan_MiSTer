#!/bin/bash
# Frozen-state video bench (jchan_video: 2 x jchan_rle + jchan_view2 + jchan_mix + palette; tb_jchan_video.cpp), run inside WSL:
#   mister/sim/run_video.sh <scenes.bin> <out-prefix> [+pixdiv=n +lat=n +rnd=seed]
# Builds once in $HOME/build_jchan/video (BUILD_DIR overrides; NOBUILD=1 reuses the build).
set -e
cd "$(dirname "$0")"
SC="$1"; OUT="$2"; shift 2 || true
[ -f "$SC" ] && [ -n "$OUT" ] || { echo "usage: $0 <scenes.bin> <out-prefix> [+pixdiv=n] [+lat=n] [+rnd=seed]" >&2; exit 2; }
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_jchan/video}"; mkdir -p "$B"
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -CFLAGS "-O3 -march=native" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -GPINGPONG=${PINGPONG:-0} --top-module jchan_video -Mdir "$B/obj" ../rtl/jchan_ram.sv ../rtl/jchan_spr_dec.sv ../rtl/jchan_spr_band.sv ../rtl/jchan_spr.sv ../rtl/jchan_view2.sv ../rtl/jchan_mix.sv ../rtl/jchan_video.sv tb_jchan_video.cpp \
    > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
"$B/obj/Vjchan_video" "$SC" "$OUT" "$@"
