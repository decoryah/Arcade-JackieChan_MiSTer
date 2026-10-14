# Kaneko RLE sprite chip pair ("CG24173 6186" + "CG24143 4181") -- specification and RTL plan

Used by jchan.cpp (x2), suprnova.cpp (SKNS, x1: "SPCII-A / SPCII-B") and galpani3.cpp. This document is derived from MAME 0.289
`kaneko_rlespr.cpp` and from the executable model `tools/jchan_spr.py`, which is a statement-by-statement port of it.

**Verification state** (rerun with the commands in section 10):
* the model equals MAME's own C++ (the device functions compiled unmodified in a harness) on 6,000+ random sprites, frame by frame, CRC of the whole
  512 x 512 bitmap, including trail mode, global flip, groups, joints, table and "grow" zoom;
* model + VIEW2 model + mixer + palette equal MAME's snapshots **pixel for pixel on 60 real frames, 30 each of `jchan` and `jchan2`** (attract,
  character select, fights; up to 660 zoomed background sprites and 294 zoomed foreground sprites per frame).

* **RTL** (`rtl/jchan_rle.sv`, section 8): bit-exact against the model, hence against MAME, on every dumped frame of both sets and both chips
  (120 chip-frames at 1-clock ROM latency, 60 more at random 1-5 clock latency) and on ~340 random frames (random latency up to 6 clocks).

What is *not* established: anything MAME itself gets wrong or does not model (section 9). Real-PCB captures are the only oracle for those.

## 1. Where it sits

Two identical chips. Chip 1: sprite list at main 500000 (16 KB), registers at 600000 (64 B), ROM = SPA (`spritegen1`, 22.5 MB used).
Chip 2: sprite list at sub 700000, registers at sub 780000, ROM = SPB (`spritegen2`, 4 MB used). Each renders its list into a bitmap
(MAME: 512 x 512 x 16 bit, two of them; the PCB has 256K x 16 DRAMs -- 42S4260, the size of one such bitmap -- by each generator); the board mixes the two with the tile
layers (`jchan_spr.mix`). The RLE stage uses FIFO7200s on the board (MAME: an 8 KB circular decode buffer).

## 2. Sprite list entry (1024 entries x 16 bytes, no end marker)

The chip works on 32-bit words. As the 68000 sees them, word k of an entry is `(w[2k+1] << 16) | w[2k]` where `w[n]` is the 16-bit 68000 word at byte
offset 2n of the entry (i.e. *the lower-addressed 68000 word is the LOW half*). Same for the registers.

```
s0  [31:30] -   [29:28] Y size  [27:26] -  [25:24] X size  [23] grow  [22:16] -  [15:13] joint  [12:11] group  [10] -
    [9] flip X  [8] flip Y  [7:6] priority  [5:0] palette
s1  [26:0] ROM byte address of the RLE stream  (27 bits)
s2  [31:24] zoom X "m"  [23:16] zoom X "s"  [15:0] X position, signed, 10.6 fixed point
s3  [31:24] zoom Y "m"  [23:16] zoom Y "s"  [15:0] Y position, signed, 10.6 fixed point
```
Size in pixels = (field + 1) * 16 per axis, 16..64. `grow` = 1 makes `s2[31:16]` / `s3[31:16]` one 16-bit "s" step (m = 0).

Joint bits (each independent): **bit 0** position = previous sprite's position + this entry's offset (no scroll, no group offset);
**bit 1** palette inherited; **bit 2** ROM address *and priority* inherited -- the RLE stream continues where the previous entry's stream ended.

## 3. Registers (16 x 32 bit, 64 B). 32-bit register k = 68000 words (2k+1, 2k) as above

| k | bits | meaning |
|---|---|---|
| 0 (RWR0) | 6 | group offsets enable |
| 1 (RWR1) | 1 / 0 | global flip X / Y (Sengekis only); positions mirror about 320 / 240 |
| | 2 | **0 = clear the bitmap before drawing** (1 = keep: galpani3's sprite trails) |
| | 3 | disable drawing (bitmap still cleared if bit 2 = 0) |
| 2 (RWR2) | 14:0 | global Y scroll, signed 15 bit, 10.6 |
| 4 (RWR4) | 14:0 | global X scroll, signed 15 bit, 10.6 |
| 6, 8, 10, 12 | 15:0 | group 0..3 X offset (signed 16, 10.6) |
| 7, 9, 11, 13 | 15:0 | group 0..3 Y offset |
| 5 (RWR5, 0x14) | | read nowhere in MAME ("sprite ram start / end is not really fixed, registers change it") |

jchan's values in play: RWR0 = 0x40, RWR3 = 0x100 / 0x200 (unused by MAME), group Y offsets 0xfc00 (-16 px), everything else 0.

## 4. RLE stream

Control byte `c`: `c[7] = 1` -> `c[6:0] + 1` literal pen bytes follow; `c[7] = 0` -> one pen byte follows, repeated `c[6:0] + 1` times.
Runs are consumed whole until `xsize * ysize` pixels have been produced: **the last run may overshoot and the surplus is dropped**; a linked entry
continues at the *next control byte*. The stream is decoded for every entry, whether or not it is on screen (the end offset feeds linked entries).
Pixels are row-major, stride = xsize. Pen 0 is transparent. An all-zero entry decodes `7f 00 7f 00` from ROM address 0 (two runs of 128 transparent
pixels, 4 bytes; VERIFIED on both sets' ROMs: draws nothing).

## 5. Placement and drawing (`jchan_spr.RleSpriteChip.draw`, `_blit_z`)

Per entry, in list order (later entries overwrite earlier ones: plain "write if pen != 0"):

1. position: `joint0 = 0`: `x = s16(s2[15:0] + scrollX)`, `y` likewise, then `+ group offset` if enabled; `joint0 = 1`: `x = s16(x_prev + s2[15:0])`.
   Everything wraps as 16 bit. (`x_prev` is the position *before* global flip.)
2. global flip: `sx = (320 << 6) - x` (10.6), flip bit toggled.
3. colour = s0[5:0] unless joint1; pri = s0[7:6] and ROM address = s1 unless joint2 (then ROM address = end of the previous stream).
4. RLE-decode the stream into the decode RAM.
5. `out = colour << 8 | pri << 14`; every drawn pixel is `pen + out` (pen != 0).
6. if all four zoom fields are 0: **plain blit**. Position is `>> 6` (floor). For flip X the sprite's right edge is the position: columns land at
   `x - 1 - col`; same for Y. Clipped to the visible window (0..319, 0..239).
7. else **zoom blit** (exact integer algorithm, all 16.16):

```
zxs = 0x10000 - m_x     zxd = 0x10000 - s_x          (m, s are the 8-bit fields << 8, or m = 0, s = 16 bit in "grow" mode)
zys = 0x10000 - m_y     zyd = 0x10000 - s_y
x = pos_x << 10  (10.6 -> 16.16), y = pos_y << 10;  clip window in 16.16
bxs = bys = 0;  src = 0
clamp (no flip: while x < clip.min: bxs += zxs; x += zxd.  flip: while x >= clip.max: bxs += zxs; x -= zxd.  same for y, and
       after the y clamp: src += (bys >> 16) * xsize)
for (ys = bys, yd = y; ys < ysize<<16 and yd inside clip; ) {          // inside: yd < clip.max  (flip: yd >= clip.min)
    for (xs = bxs, xd = x; xs < xsize<<16 and xd inside clip; ) {
        pen = decode[src + ((xs >> 16) & 0x3f)];  if (pen) bitmap[yd>>16][xd>>16] = pen + out
        do { xs += zxs; xd += (flip ? -zxd : zxd); } while (((xd ^ old_xd) >> 16) == 0);      // until the integer x changes
    }
    old_ys = ys
    do { ys += zys; yd += (flipY ? -zyd : zyd); } while (((yd ^ old_yd) >> 16) == 0);
    for (r = (ys - old_ys) integer rows crossed) src += xsize                    // whole source rows crossed
}
```
   * with `m = 0`: `s` > 0 *skips* source pixels (shrink); with `s = 0`: `m` > 0 *repeats* them (magnify). Both = jchan's "08 08" backgrounds: a step of
     0xf800 on both sides, i.e. an almost-1:1 copy that drops / repeats a pixel every 32.
   * `xs`, `ys` are u32 (they wrap in a pathological `s`), `xd`, `yd` int32.
   * The flipped zoom blit starts **at** the position (first column at `x`), the plain flipped blit at `x - 1`: MAME keeps this 1-pixel difference.

## 6. Frame timing (VERIFIED on `jchan`)

* MAME updates the screen at the start of the vblank (line 240) and then, in its `vblank` timer callback of the same line, copies both sprite RAMs
  into the chips' 32-bit buffers.  So the list drawn for frame N is the copy made at line 240 of frame N-1 = the live list as it stood at that line
  (MAME's dump N-1 is taken at the same instant); the registers (RWR*), the tile RAM, the VIEW2 registers and the palette are those of line 240 of
  frame N itself.  (Measured: in fight frames the picture matches only that list.)
* MAME draws the whole frame at once.  For RTL: latch the lists at line 240, render during the next frame and display in the frame after
  (`memory.md` 5: the state of line 240 is snapshotted, the picture is scanned out one frame later).

## 7. Workload (measured by `tools/jchan_budget.py` over 60 frames of play, 30 per set; every used entry is 16 x 16)

| per frame | chip 1 (SPA) | chip 2 (SPB) |
|---|---|---|
| entries not all-zero | up to 414 (typ. 135-200 in a fight) | up to 660 (a fight: 270-530, all zoomed, 90% linked) |
| RLE bytes read from ROM | up to 94.5 KB | up to 113.1 KB (4 bytes of that per empty entry) |
| pixels decoded | **262,144 always** (1024 x 256) | 262,144 |
| destination positions visited | up to 113,841 | up to 85,805 |
| pixels written | up to 106,436 (overdraw: more than the 76,800 of the screen) | up to 82,404 |

The decode work is constant (every entry, even empty ones, runs its 256 pixels). The RLE stream is read strictly sequentially (linked entries
continue it), so a prefetching burst reader is enough; ROM traffic is up to ~208 KB per frame in total = 12.5 MB/s.

## 8. RTL

### 8.0 Status: `rtl/jchan_rle.sv` v3 (one chip; instantiate twice) -- correct and optimised (v1 / v2 are kept in `work/rtl_v1`)

> The core no longer uses this whole-bitmap engine: its decoder and blitters were split into pass 1 (`jchan_spr_dec.sv`: decode once, store the decoded
> sprites in the SDRAM) and pass 2 (`jchan_spr_band.sv`: draw 16-line bands from the store into a ring), see `memory.md`.  v3 is kept as a second
> implementation of the same behaviour (its bench still runs in `tools/regress.py`).

Ports (memory style, so the same module sits behind SDRAM and the CPU-side latch): `start` / `busy` / `done`, `regs` (512 bit, latched at start),
`n_entries`, `list_addr` -> `list_data` (block RAM, one clock), the ROM as a **pipelined byte stream** (`rom_req` / `rom_addr` / `rom_ready`, in-order
`rom_valid` + `rom_data`, any latency), `fb_we` / `fb_addr` {y[8:0], x[8:0]} / `fb_data` {pri, colour, pen} / `fb_bank` (MAME's two bitmaps),
`clear_en`, `kludge_x/y` (0 on the board).

Structure: two engines run concurrently.
* **Decoder**: list fetch (5 clocks) + geometry (1), then the RLE decode into one of two decode RAMs (4 byte lanes x 2K each). A 16-byte prefetch FIFO
  runs ahead of it (a repeat control byte and its value are taken together; the FIFO carries on across linked entries and is flushed and restarted
  only at an unlinked one). The RAMs are kept **all zero between entries**: a transparent run costs one clock whatever its length, an opaque repeat run
  is written 4 pixels / clock, literals one a clock.
* **Blitter**: gets the entry (descriptor copy + RAM number) when it is free; plain blit 1 pixel / clock, which zeroes every opaque pixel it has read; zoom
  blit = MAME's 16.16 DDA, one adder step per clock with the pixel read / write pipelined, zeroing the rows it has left behind a word per clock.
* An entry without an opaque pixel never reaches the blitter; a plain entry entirely outside the window is only cleaned up.
* `clear_en = 0` leaves the 320 x 240 clear to the scan-out (`jchan_video`: `CLEAR_ON_SCAN`, see `video.md`); the first two frames after reset are
  always cleared here (the memory holds garbage).

yosys: ~750 word-level cells, 8 byte-lane RAMs of 2K x 8 + the 16-byte FIFO, two small multipliers, no latches; Verilator lint clean. Not yet
through Quartus (`work/rtl_v1/` has the earlier versions for A/B).

Bench: `sim/tb_jchan_rle.cpp` + `sim/run_rle.sh` (Verilator 5 from your OSS CAD suite, builds in `$HOME/build_jchan/rle`), driven by
`tools/bench_rle.py` (`random` / `frames <set>`): loads a dumped list + registers, runs the RTL, CRC32 of the whole 512 x 512 bitmap vs
`tools/jchan_spr.py`. Options: `+lat=n +rnd=seed` ROM latency / random latency, `+depth=n` outstanding requests the ROM model accepts, `+clear=0`
(engine told not to clear; the bench zeroes the displayed window like the scan-out). Verified exact on every dumped frame (both sets, both chips), on
random lists with random latency / shallow queues / 3-4 frames per case with `clear_en = 0`, and in the whole video path (`video.md`).
`tools/profile_rle.py <set> <chip> <frame>` prints the state histograms of both engines for one steady-state frame (Verilator `--public-flat-rw`).

**Render time** (RTL clocks, ROM latency 1; the whole video path on a running machine, both chips in parallel, `spr_start` -> `done`):

| | v1 (one engine, byte handshake) | v3 |
|---|---|---|
| `jchan`, median / max over 30 frames | 0.62-0.65 M / 0.90 M | **103 K (1.07 ms) / 117 K (1.22 ms)** |
| `jchan2`, median / max over 30 frames | 0.66-0.72 M / 1.03 M | **117 K (1.22 ms) / 193 K (2.01 ms)** |

(ms at 96 MHz of a 16.8 ms frame.) The heaviest frame (jchan2 f1320, 660 zoomed entries): decoder busy 148 K (literal bytes 82 K at 1 / clock, opaque
repeat runs 39 K, control bytes 20 K), blitter busy 174 K (zoom steps 120 K, row overhead 43 K), the two overlap. What is left, if it is ever needed:
(a) a 16-bit ROM stream (2 bytes / clock = the native SDRAM burst; literals are the biggest decoder item), (b) two DDA iterations per clock for the
steps that skip a source pixel (~30 % of the zoom steps in the 660-entry frame), (c) fusing the row-end / y-step states (~15 K), (d) taking the
next control byte together with the last pixel of a run. Together they should give roughly 125 K for the heaviest frame (an estimate, not measured).

**Latency note.** MAME draws frame N from the list latched at line 240 of frame N-1 and shows it at once. A render of 1.1-2 ms is longer than the
21-line vblank (1.35 ms), so a core that renders in real time shows the sprites of frame N starting a few lines into frame N unless the bitmap
swap is delayed by a frame (sprites one frame later than MAME relative to the tiles). Which one the PCB does is not known; it is a decision for the
integration (video.md), and (a)-(d) above are what would let the render fit the vblank.

The mixer, the VIEW2 tile layers and the whole video path around the two chips are in `video.md`.

### 8.1 Plan / context

```
sprite RAM  (2 x 16 KB BRAM, CPU port + renderer port; latched copy made at line 240)   regs: live, 16 x 32 bit
   -> entry unit: fields, joint / group / global flip, position arithmetic (s16 wraps)         ~1 entry / 4 clk
   -> RLE fetch: SDRAM bursts from the entry's byte address, 8-bit FIFO, "end offset" register
   -> decode RAM: 4224 bytes minimum (4096 + one 128-byte overshoot); MAME has 8 KB circular
   -> blitter: plain (1 px / clk) or zoom DDA (jchan_spr._blit_z; 16.16 adders, no multipliers)
   -> framebuffer write: 16-bit words {pri, colour, pen}, only where pen != 0
scan-out: tile pipeline (VIEW2) + two framebuffer reads + `mix` + palette (32K x 16 BRAM) -> video
```

* **Framebuffers**: the model's bitmaps are 512 x 512 x 16 but only the 320 x 240 window is ever written (clip) -> 150 KB each; 2 chips x 2 buffers =
  600 KB, which is all the M10K there is (696 KB) -> keep them in SDRAM (traffic: writes <= 190 K words, scan-out 2 x 77 K words, clear: ~1 MB / frame
  = ~60 MB/s of ~190 MB/s at 96 MHz) or find a cheaper trick (clear-on-scan-out: the reader writes the zero back).
* **Time**: decode 262 K + blit <= 114 K clocks per chip per frame = ~3.9 ms at 96 MHz (of 16.8 ms); the two chips run in parallel. No scan-line
  renderer is needed. The budget assumes the sampled workloads; the real maximum over a full game is not known -- record it with the Lua dump over
  a longer run (`dst_steps` / `dec_px`) before sizing anything near the limit.
* **ROM**: chip 1 reads up to 27 bits (jchan uses < 23.6 MB); put SPA, SPB, tile ROM, YMZ ROM, programs in a 64 MB SDRAM image (~33.9 MiB).

## 9. Open questions / things MAME does not settle

* RWR5 (0x14) -- list start / end? MAME always walks 1024 entries from the start. Equal to MAME for every verified frame.
* "Zooming precision / rounding is not right, most noticeable on jchan backgrounds" (MAME's TODO). The model equals MAME, not the PCB.
  `kaneko_rlespr.cpp` cites a video of the real PCB (https://youtu.be/PJijmhRwMUk) as reference.
* Group offset behaviour on SKNS games (Gals Panic), the "grow" mode (Sengekis, Gals Panic S2): not exercised by jchan; the model matches MAME's guess.
* Sprite / tile priority and the 15th palette bit are marked unverified by MAME (mixer is a literal port).
* Maximum workload of the real game (see section 7).

## 10. Re-running the checks

```
py -3.8 mister/tools/jchan_rom.py jchan                       # builds work/rom/jchan.*.bin from the zip, CRC checked
py -3.8 mister/tools/xcheck_rlespr.py --cases 80 --seed 2     # model vs MAME's C++ (builds the harness with g++ in the WSL)
py -3.8 mister/tools/mamedump.py --play jchan                 # MAME + lua/dump.lua -> work/mame/dumps, work/mame/snap
py -3.8 mister/tools/jchan_frame.py jchan                     # model vs MAME snapshots, every dumped frame
py -3.8 mister/tools/jchan_budget.py jchan                    # workload table
py -3.8 mister/tools/bench_rle.py random --cases 60 --seed 1  # RTL vs model on random lists (Verilator in the WSL; builds on first use)
py -3.8 mister/tools/bench_rle.py frames jchan                # RTL vs model on every dumped real frame, both chips
```
