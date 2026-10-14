# jchan_core on the DE10-nano's Cyclone V (Quartus 17.0.2 Lite)

The project fits `jchan_core` (both 68000s, board, toybox, VIEW2, both sprite chips, mixer, palette, YMZ280B, 48 kHz stage) alone, without the
MiSTer framework, the SDRAM controller `jchan_mem` or the loader: a place to count resources and close the timing of the core.

| file | |
|---|---|
| `jchan_core.qpf` | project, two revisions |
| `jchan_core.qsf` | revision `jchan_core`: sources, device 5CSEBA6U23I7, `ALLOW_ANY_RAM_SIZE_FOR_RECOGNITION` |
| `jchan_fit.qsf` | revision `jchan_fit`: the same with every port a virtual pin (`jchan_virtpins.qsf`), so that it fits |
| `jchan_core.sdc` | the 96 MHz clock and the multicycle paths of the CPUs (see the file: they depend on the CPUs' phase enables 3 clocks apart) |
| `run_fit.ps1` | map + fit + timing analysis of `jchan_fit` (about 15 minutes, 7 GB) |
| `sta_report.tcl`, `sta_groups.py` | the worst path of every endpoint in the two slow models, grouped by block (`quartus_sta -t sta_report.tcl`) |

```
powershell -File run_fit.ps1
```

## Result (RTL of 2026-10-13, `jchan_fit`)

| | |
|---|---|
| ALMs | ~11.7 K of 41,910 (28 %) |
| registers | ~14.3 K |
| block memory | 4,528,192 bits, **552 of 553 M10K blocks** |
| DSP | 20 of 112 |
| setup slack, slow 1100 mV 100 C / -40 C | **+0.95 / +0.69 ns** |
| setup slack, fast 1100 mV 100 C / -40 C | +5.4 / +6.2 ns |
| hold slack (all four) | >= +0.10 ns |

`docs/memory.md` section 8 has the RAM budget and what the synthesis taught (explicit `altsyncram` for the true dual-port RAMs, byte arrays for
the byte-enabled single-port RAMs, no three-port arrays).

## How the timing was closed (from -5.3 ns)

* Registered RAM write enables in `jchan_board.sv` (the write happens the clock after the bus cycle's first; address, byte enables and data stay put).
* SDC multicycle paths for everything inside fx68k, from its address bus and function-code registers, and from the board's RAM outputs into its data
  input latches (`jchan_core.sdc`).
* `jchan_ymz280b.sv`: the voice being processed is loaded into working registers (`E_VLOAD`), the ADPCM step is four stages, the half-product and
  the output saturation have their own states.  Verified bit-exact against MAME's chip code (random stress, the captured 25 s session).
* `jchan_audio48.sv`: sum, multiply and shift in three clocks.
* `jchan_spr_band.sv`: the geometry arithmetic of the table T in four stages (`G_C1 .. G_C4`), the ring write registered once more, the plain-blit
  row index in its own state.
* `jchan_toybox.sv`: running addresses instead of adders in the port path, the mailbox strobe registered, a wait state before the first RAM access
  so that the board's registered port select (`tb_busy_q`) is in time; the board holds the main CPU's mcuram cycles while the toybox owns the port.
* `jchan_snapram.sv`: the scan has a register between the live RAM's output and the display copy's input; `jchan_video.sv`: the palette address
  is registered.

## The whole project

`../Jchan.qpf` is the real MiSTer project (framework + core + memory system).  `sta_jchan.tcl` (worst setup path of every endpoint of the machine
clock, group with `sta_groups.py`) and `sta_corners.tcl` (the four timing models) are run from `mister/` with `quartus_sta -t quartus/<script>`;
results in `docs/mister_top.md`.
