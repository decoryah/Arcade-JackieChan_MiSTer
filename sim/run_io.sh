#!/bin/bash
# Input-port bench (rtl/jchan_io.sv + tb_jchan_io.cpp), run inside WSL:  run_io.sh <combos.txt> <out.txt>
set -e
cd "$(dirname "$0")"
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_jchan/io}"; mkdir -p "$B"
verilator --cc --exe --build -j 4 -O1 -Wno-fatal -Wno-WIDTH --top-module jchan_io -Mdir "$B/obj" ../rtl/jchan_io.sv tb_jchan_io.cpp > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head; exit 1; }
"$B/obj/Vjchan_io" "$1" "$2"
