#!/bin/bash
# Toybox bench (rtl/jchan_toybox.sv + tb_jchan_toybox.cpp), run inside WSL:
#   mister/sim/run_toybox.sh <vectors.txt> <mcudata.bin> [maxfail]
# Builds once in $HOME/build_jchan/toybox (BUILD_DIR overrides; NOBUILD=1 reuses the build).
set -e
cd "$(dirname "$0")"
V="$1"; M="$2"; shift 2 || true
[ -f "$V" ] && [ -f "$M" ] || { echo "usage: $0 <vectors.txt> <mcudata.bin> [maxfail]" >&2; exit 2; }
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_jchan/toybox}"; mkdir -p "$B"
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -CFLAGS "-O2" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTH \
    --top-module jchan_toybox -Mdir "$B/obj" -I../rtl ../rtl/jchan_toybox.sv tb_jchan_toybox.cpp \
    > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
"$B/obj/Vjchan_toybox" "$V" "$M" "$@"
