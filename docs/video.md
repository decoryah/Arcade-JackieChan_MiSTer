# jchan video RTL: VIEW2 tiles + mixer + palette + the two sprite chips (`jchan_video`)

What exists (all in `mister/rtl/`), what it was checked against, and what it does *not* yet do. The sprite chip itself is in `rle_sprites.md`.

> **Update (memory system).**  The sprite bitmaps of the v3 engine described in sections 1, 3 and 4 below (two chips x two 320 x 240 x 16 bit banks,
> `CLEAR_ON_SCAN`, `fbN_*` ports) were replaced by the banded renderer of `memory.md`: `jchan_video` now holds two `jchan_spr` chips (pass 1 decode +
> SDRAM store, pass 2 bands into a 4 x 8-line ring) and reads / clears the rings at the pixel clock.  The sprite list and registers are latched at
> line 240, the tile RAM / palette / VIEW2 registers follow the live state until line 259 and are frozen from line 260 (`memory.md` 5), and the picture is
> scanned out one frame later, so the "live per line" latch policy of section 4 is gone: sprites, tiles, palette and registers are all MAME's
> end-of-frame state.  The frozen-state bench (`tools/bench_video.py`, `sim/tb_jchan_video.cpp`) was ported: reset, pass 1, wait for line 240, pass 2,
> scan out the next frame -- 0 differing pixels against MAME's snapshots on jchan (30 frames) and jchan2 (30 frames, running machine, random ROM
> latency, store write stalls and read latency 12).  The VIEW2 / mixer / palette parts (sections 2, 3) are unchanged.

| module | |
|---|---|
| `jchan_rle.sv` | one RLE sprite chip (instantiated twice) |
| `jchan_view2.sv` | the two tile layers, rendered a display line ahead into ping-pong line buffers |
| `jchan_mix.sv` | the final sprite / tile mixer (`tools/jchan_spr.py mix()`), combinational |
| `jchan_video.sv` | raster counters, the line-render trigger, the tile-layer merge, the two chips, the palette read and the RGB output |

## 1. Verification (frozen state, `tools/bench_video.py`, Verilator)

The bench loads a dumped MAME state (both sprite lists as MAME draws them, the live sprite / VIEW2 registers, tile RAM, palette), resets the RTL, lets
both sprite chips render, scans out one complete frame and compares the 320 x 240 RGB picture with **MAME's own snapshot of that frame**:

| run | frames | differing pixels |
|---|---|---|
| `jchan` + `jchan2`, all dumped frames (attract, character select, fights), pixel clock every 12 clocks, ROM latency 1 | 60 | **0** |
| `jchan`, pixel clock every 13 clocks (96 MHz / 7.159 MHz) | 2 | 0 |
| `jchan` / `jchan2`, pixel clock every 5 / 4 clocks, random ROM latency up to 6 / 4, 15-bit palette index also compared with the Python model | 8 | 0 (RGB and index) |
| `jchan`, pixel clock every 13, random ROM latency up to 12 | 2 | 0, no line overrun |
| `jchan` and `jchan2` **on a running machine** (`--noreset`: the 30 frames of a set back to back, no reset in between; bank switching and the scan-out clearing in use), pixel clock every 12; `jchan2` again with pixel clock every 5, random ROM latency up to 4, ROM queue depth 8 | 60 + 30 | **0** |
| negative control: the same run with the scan-out clearing writes ignored (`--nocw`) | 6 | 50-59 K pixels differ in the frames after the first two, as it must |

Rerun: `py -3.8 mister/tools/bench_video.py <set> [--frames ..] [--pixdiv n] [--lat n] [--rnd seed] [--depth n] [--noreset] [--nocw] [--model]`
(`tools/video_clocks.py <set>` summarises the sprite render times of the last run).

## 2. VIEW2 line renderer (`jchan_view2`)

* Renders display line n+1 while the scan-out reads line n (two parities x two layers x 320 x 14 bit `{op, category[2:0], index[9:0]}`).
* Per layer and line: line-scroll word (if enabled) -> scroll / column / tile row arithmetic (`tools/jchan_tiles.py` header = the formulas) -> 21
  tiles: attr word, code word, two 32-bit ROM words (the 16 pixels of the tile row; flip X is a pixel reorder, flip Y a row-select), 16 line-buffer
  writes. Transparent pixels are written too (they must overwrite the previous line's).
* **Render time per line** (clocks, from `view2_busy`): 976 with 1-clock ROM latency, 1,532 with random latency up to 12, 1,131 with random
  latency up to 4 -- against 6,168 available per line at 96 MHz (a pixel clock every 13.4 clocks x 460) and still under the 1,840 of a 4-clock pixel
  clock. `view2_overrun` (sticky) flags a line start while busy; never set in these runs.
* Ports: tile RAM read (8192 words, 1 clock), tile ROM read (32-bit word address, request / valid), scan-out read.

## 3. Mixer, palette, raster (`jchan_mix`, `jchan_video`)

* Tile winner of the two layers: FG over BG unless BG's category is higher (the drawing order of `kaneko_tmap`); then `jchan_mix`: category >> 1
  against the sprite priorities, chip 2 wins ties, pen 0 transparent, background index 0x7f00. Output = 15-bit palette index.
* Palette RAM read port (32768 x 16, 1 clock): `pal_data` xGRB555 -> 8-bit RGB with `pal5bit` (`v << 3 | v >> 2`); `o_idx` is the index.
* Read pipeline is 2 clocks deep (line buffers + sprite bitmaps, then palette), so `ce_pix` must be >= 4 clocks apart; the output register samples
  it at the pixel enable.
* Raster: 460 x 261, 320 x 240 visible, starts on line 260 so line 0 is rendered before the first visible line. **Sync pulse positions are
  placeholders** (`hs` 340-371, `vs` 244-246): MAME only fixes the totals and the visible area; the PCB's 15.556 kHz / 59.601 Hz are measurements
  (hardware.md section 2). Pick them when the output stage is written.
* **Sprite bitmap banks.** Each chip toggles its bank at `spr_start`. The bank scanned out is the one of the last completed render, and a newly
  completed render takes over **at the next frame start** (never in the middle of a scan).
* **`CLEAR_ON_SCAN`** (parameter, default 1): the engines do not clear their 320 x 240 window (`clear_en = 0`); when the scan switches to a new
  bank it writes 0 into the bank it has just left, pixel for pixel as it displays the new one, so a bank is clean again before it is next drawn
  (saves the 77 K-clock clear pass per chip). Valid only for boards that never leave RWR1 bit 2 set (jchan: RWR1 = 0 in every dump); with
  trail-mode games the engines must clear (`CLEAR_ON_SCAN = 0`). The engines clear the first two frames after reset themselves. If a frame is
  not rendered, no switch happens and nothing is cleared (the displayed bank stays intact).
* Ports: the sprite ROMs are pipelined byte streams (`romN_req/addr/ready`, in-order `romN_valid/data`); each chip also has a clear-on-scan write
  port `fbN_cw_we/addr/bank` (zero at {y, x} of the bank it left).

## 4. What is not done / decisions that belong to system integration

* **Screen flip** (VIEW2 control bits 9 / 8, the flip DIP) is not implemented in `jchan_view2` or the Python reference.
* **Latch policy.** The sprite lists are used as latched at line 240 of the previous frame (that is what MAME draws; `jchan_board` does the copy and
  fires `spr_start`). Tile RAM, VIEW2 registers and the palette are read *live, per line* here (as the chip would); MAME renders a frame at once from
  the state at vblank. With a frozen state they are identical; with a running CPU a mid-frame write shows from that line on instead of next frame.
  **Checked with the whole machine** (`docs/cpu_side.md` 4.3): 29 pictures from reset between frame 439 and 999, scene changes and scrolling text
  included, are pixel-identical to MAME's snapshots, so the live policy needs no latch for this game's frames.
* Tile RAM, palette RAM and the sprite list latch are plain memories behind the ports; their CPU-side write ports, the sub / main bus decode and
  the two frame-buffer memories (2 chips x 2 banks x 320 x 240 x 16 bit = 600 KB) are not written.
* Sprite render time is now 0.24-1.2 ms (`jchan`) / 0.14-2.0 ms (`jchan2`) at 96 MHz on the running machine (rle_sprites.md 8.0), against a 1.35 ms
  vblank; everything else here is a small fraction of a line. Whether the sprite bitmap swap may lag by a frame behind MAME's (see the latency
  note there) is an integration decision.
* Not through Quartus; `yosys` / Verilator lint see no latches; memories: two 8 KB decode RAMs per sprite chip (4 lanes x 2K x 8 each), 16-byte ROM
  FIFO per chip, two 1024 x 14 line-buffer RAMs for the tiles.

## 5. Re-running

```
py -3.8 mister/tools/mamedump.py --play jchan                  # (once) MAME states + snapshots -> work/mame
py -3.8 mister/tools/bench_video.py jchan                      # full video path vs MAME's snapshots
py -3.8 mister/tools/bench_video.py jchan2 --frames 1320,3240 --pixdiv 4 --lat 4 --rnd 9 --model
```
