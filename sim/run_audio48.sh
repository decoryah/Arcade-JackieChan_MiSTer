#!/bin/bash
# 48 kHz output stage bench (rtl/jchan_audio48.sv + tb_jchan_audio48.cpp), run inside WSL.
set -e
cd "$(dirname "$0")"
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_jchan/audio48}"; mkdir -p "$B"
verilator --cc --exe --build -j 4 -O2 -Wno-fatal -Wno-WIDTH --top-module jchan_audio48 -Mdir "$B/obj" ../rtl/jchan_audio48.sv tb_jchan_audio48.cpp \
    > "$B/build.log" 2>&1 || { grep -E "%Error|error:" "$B/build.log" | head; exit 1; }
"$B/obj/Vjchan_audio48"
