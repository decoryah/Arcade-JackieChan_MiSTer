# Vendored modules

Third-party HDL copied into the tree (no submodules), each with its own LICENSE / README alongside.

| module | upstream | licence |
|---|---|---|
| cpu-fx68k | FX68K, Jorge Cwik (see its README.md) | GPL-3.0 |
| crt-adjust | https://github.com/rmonic79/MiSTer-CRT-Adjust @ c682de9f4acc61d8f4c7779efb48149d3baa3a8e (upstream's `rtl/crt_adjust.sv`; one local fix, below), rmonic79 (Umberto Parisi) with Andrea Bogazzi (asturur); copied from the owner's metamrph-mister | GPL-3.0 or later |

Local change to `crt-adjust/crt_adjust.sv` (one line, `hoff_s`): the conditional mixes `$signed(hoffset)` with an unsigned replication, so
by the Verilog rules (and in Verilator) the result is unsigned and a negative H-Position is zero-extended (-1 becomes 511), which moves the
picture window out of the line and blanks the picture.  The line now sign-extends `hoffset` explicitly.  Nothing else differs from upstream.
