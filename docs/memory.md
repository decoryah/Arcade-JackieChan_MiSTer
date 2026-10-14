# jchan memory system: SDRAM map, controller, client adapters, banded sprite renderer

What exists in `mister/rtl/`, `mister/sim/`, `mister/tools/`, what it was checked against, and the decisions behind it.

| module | |
|---|---|
| `jchan_sdram.sv` | the SDRAM controller: 64 MB module, CL2 / BL1, close page, NP generic burst ports in fixed priority order |
| `jchan_mem.sv` | the core's memory system: controller + one adapter per ROM port of `jchan_core` + the sprite stores' ports + the download loader |
| `jchan_spr_dec.sv` | sprite chip, pass 1: RLE-decodes every list entry once and stores the decoded sprites in the SDRAM |
| `jchan_spr_band.sv` | sprite chip, pass 2: geometry scan, then draws the frame in 8-line bands from the store into a 4-band ring |
| `jchan_spr.sv` | one chip = pass 1 + header RAM + pass 2 |
| `jchan_rle.sv` | the v3 monolithic engine (whole-frame bitmap); no longer used by the core, kept as a second implementation of the same behaviour |
| `sim/jchan_sdram_model.sv` | behavioural 64 MB SDRAM with the 96 MHz timing checks (tRC 6 / 7, tRP, tRFC, tRAS, tRRD, bus turnaround, refresh gap) |
| `tools/jchan_sdram_image.py` | builds the SDRAM image of a set from `work/rom/<set>.*.bin` |

## 1. SDRAM image (byte addresses of the 64 MB module)

One word = 16 bit, even byte address in `[15:8]` (the 68000 convention used by every client).  Word address = `{BA[1:0], row[12:0], col[9:0]}`, so a
bank is 16 MB of byte address and a row 2 KB.

| address | size | content |
|---|---|---|
| `0x0000000` | 2 MB | main 68000 program (MAME `maincpu`) |
| `0x0200000` | 1 MB | sub 68000 program |
| `0x0300000` | 1 MB | VIEW2 tile ROM (32-bit words, bytes in file order) |
| `0x0400000` | 3.25 MB | YMZ280B samples, compact: MAME region `0x000000-0x0fffff`, `0x200000-0x3fffff`, `0x400000-0x43ffff` (the mirror at `0x100000` is folded away in `jchan_ymzrd`) |
| `0x1000000` | 24 MB window | sprite chip 1 ROM (SPA, 22.5 MB used) -- banks 1 and 2 |
| `0x3000000` | 4 MB | sprite chip 2 ROM (SPB) -- bank 3 |
| `0x3800000` | 4 x 2 MB | decoded-sprite stores: chip 1 windows at `0x3800000` / `0x3a00000`, chip 2 at `0x3c00000` / `0x3e00000` (parity = list bank) |

The toybox data ROM (22 KB are ever read) is loaded into block RAM by the loader's `ld_*` side port, not into SDRAM.
The ROM total is 33.75 MiB: a 32 MB module is too small, a 64 MB one (10 column bits, as `metrof64`) is required.

## 2. Controller (`jchan_sdram`)

Physical layer from metro-mister's `metro_sdram.sv` (runs on hardware at 96 MHz): command encoding, mode register `0x020` (BL1, CL2), init
(100 us, PALL, 2 x REF, MODE), read capture `P_RET = 3` (+1 with `i_rd_late`), refresh every 750 clocks.  New: the client side.

* **Ports**: `NP` ports, `req[p]` / `addr[p]` (25-bit word address) / `len[p]` (1..64 words); `ack[p]` pulse when granted; read data comes back
  in order with `rvalid[p]` / `rlast[p]`; write ports are *pulled*: `wavail[p]` + `wdata[p]`, `wpop[p]` per consumed word.  Lowest index = highest
  priority; a grant is never interrupted (CPUs: 8-word line fills, bulk streams: 16-word bursts, sprite store chunks: up to 64 words).
* **Timing guards**: a down-counter per bank for ACT-to-ACT (7 clocks), READ + auto-precharge (ACT 3 clocks after the READ), WRITE + AP (5), and a
  global one for tRFC / tMRD.  A request whose bank is not ready is skipped, so accesses to different banks follow each other without waiting.
* **Row crossing**: a burst that reaches column 1023 is continued in the next row (re-ACT).
* **No byte masks**: DQM is tied low; every write is a full word.  (This is also why the sprite bitmaps could not live in the SDRAM: see 5.)

## 3. Clients (`jchan_mem`, priority order)

| port | client | protocol seen by the core | behind it |
|---|---|---|---|
| 0 | loader | `dl_wr` / `dl_addr` (26-bit byte address) / `dl_data`, `dl_busy` | bytes paired into words, 16-deep FIFO, one word per grant |
| 1 / 2 | main / sub program ROM | `req` held, `ack` level with data (jchan_cyc's `ext_ack`) | direct-mapped 2 KB cache, 8-word lines, next-line prefetch; hit = same clock |
| 3 | YMZ280B | `rom_req` held until the one-clock `rom_ack` | one-word cache (ADPCM reads consecutive bytes), region fold |
| 4 | VIEW2 tile ROM | `rom_req` / `rom_waddr` held until `rom_valid` pulse with 32 bits | 2-word burst |
| 5 / 6 | sprite pass 2 store reads (chip 1 / 2) | `sr_req` / `sr_addr` / `sr_len`, `sr_ack`, `sr_valid` words | -- |
| 7 / 8 | sprite chips' ROM | jchan_rle's pipelined byte stream (`rom_ready`, in-order `rom_valid`) | 16-word prefetching burst window (64-word ring); an address outside the window restarts it |
| 9 / 10 | sprite pass 1 store writes (chip 1 / 2) | `st_req` / `st_addr` / `st_len`, `st_ack`, pulled `st_avail` / `st_data` / `st_pop` | -- |

## 4. Results of the memory system alone (ROM clients; sprites still on the v3 engine's bitmaps at that point)

* `sim/run_mem.sh` (unit bench, `tools/regress.py` step `mem`): all client kinds at once with random patterns, loader writes read back through the
  caches / streams: **0 mismatches** over 300 K+ clocks, **0 timing violations** of the model (tRC6 / tRC7 / tRRD / tRP / tRFC / tRAS / bus), refresh
  gap <= 766 clocks.  Found and fixed on the way: ACT 1 clock inside tRP after a short read burst (the count decrements at the edge that sets it).
* Whole core from reset through the controller, 200 frames (zero-wait before): **every CPU-visible memory equal to MAME at frames 100..200 (3-4
  bytes of the sub CPU's stack residue differ as before), 6 / 6 pictures pixel-identical, 0 timing violations**, controller busy 9 % of the clocks.
  The CPUs run with the cache's wait states (a miss costs ~10 clocks, i.e. 1 - 2 CPU clocks).

## 5. Sprite bitmaps: decision

The v3 engine draws into four 320 x 240 x 16 bit bitmaps (2 chips x 2 banks = 4.9 Mbit): too much block RAM next to the rest (about 3.9 Mbit
without them).  In the SDRAM the pixels would have to be written one word at a time (no byte masks: transparent pixels can not be skipped inside
a burst), ~1 M clocks of random single-word traffic for the heaviest frames plus the scan-out reads and clears -- a heavy frame (jchan2: up to
660 zoomed entries per chip) would not be drawn within the vblank.

Decision: **render in bands**.  The chips are two passes:

1. **pass 1 (once per list, any time in the frame)**: decode every entry exactly as the v3 decoder does and store the *decoded sprite* (the 32-bit
   decode-RAM words from the first to the last opaque pixel) in the SDRAM, plus a header per entry (valid, store offset, word span, extents).  It
   needs only the list and the ROM -- no registers, no positions.
2. **pass 2 (once per picture, paced by the display)**: with the snapshot of the registers, a geometry scan of the list gives every entry's
   position, flips, colour / priority (the joint chain) and the bands it touches; then for band 0 .. 14, in list order, every entry that touches the
   band is DMA'd back from the store into a blit RAM and drawn by the v3 blitters (plain: only the rows inside the band; zoom: MAME's DDA with the
   clip rectangle = the band) into a ring of 4 bands x 8 lines x 320 pixels.  The display reads the ring and zeroes what it has read; band b + 4
   is drawn into band b's slot once the display has passed it.

The model's own clip argument shows this is exact: drawing a band with `clip = band` equals the full draw cropped (the clamp loops advance the
DDA through the same positions; a step never skips a destination row because zyd <= 1.0) -- checked on random lists (`tools/bench_spr.py`).

**Latency: one frame more than the v3 core, and which state the picture is made of.**  MAME updates the screen at the start of the vblank
(`screen_device::vblank_begin` -> `frame_update`, line 240; the `frame_done` callbacks of the dump scripts run right after it), and its `vblank`
timer callback of the same line then copies both sprite lists and raises the main CPU's level 1 interrupt.  So the picture of frame N is made of
the tile RAM, palette and registers *as they are at line 240 of frame N* and of the list copied at line 240 of frame N-1.  The v3 core displayed
the picture in frame N with tiles / palette live per line, which is the same for every game that does not write them during the scan -- but a
writer in the active period (jchan2's palette entry 1 is rewritten at line 37 of every frame) shows as a tear, and the sprite render did not
fit the 21-line vblank for the heaviest jchan2 frames (median 1.2 ms, worst 2.0 ms against 1.35 ms).  Now the state of line 240 is snapshotted
and the picture is scanned out during the NEXT frame (pass 1 of the list then has a whole frame, pass 2 the vblank plus the scan itself): the
sprite list is copied at line 240 (4096 clocks, the CPU's accesses to the live list RAM are held meanwhile); the tile RAM and the palette have
display copies (`jchan_snapram.sv`: one scan L -> D of <= 17.4 K clocks started by the line-240 event; a CPU *write* to an entry the scan has not
read yet waits for it (at most one pass, 0.18 ms; reads never wait); unit bench `sim/run_snapram.sh`); the VIEW2 registers and
the sprite registers are latched at line 240.  Input to picture: +16.7 ms.

**Frame numbers.**  MAME's frame N (0-based; dumps and snapshots are labelled with `frame_number()` inside the frame) is drawn at line 240 of
that frame, which is the RTL's (N + 1)-th line-240 event: the RTL counts events and pictures from 1, so *MAME's frame N pairs with the RTL's
dump N + 1 and picture N + 1* (`tools/sys_compare.py` `--shift 1`, the default).  Comparing the labels directly makes a 1-frame-late picture
out of every frame in which a value changes (a blinking palette entry, a text line being printed): that was mistaken for a snapshot-semantics
problem for a while.  What is left after pairing correctly are the frames where the RTL's CPUs are a few microseconds behind MAME's (toybox
commands take 15 us in the RTL and no time in MAME's HLE): a game state that MAME reaches just before line 240 and the RTL just after, e.g. jchana
frame 441 (the "Check F : Ok" line).  `tools/rtl_selfcheck.py` takes those out of the picture: it renders the RTL's own dumped state of an
event (tile RAM, palette, registers, latched lists) with the reference model and compares it with the picture the RTL scanned out.

## 6. Banded renderer details

* **Pass 1** (`jchan_spr_dec`): list fetch (4 words), the v3 prefetching ROM stream and decoder (zero-skip decode RAMs, ping-pong), then a store unit
  that reads the span out of the RAM (zeroing it behind the read), and writes it through the controller's write port in chunks of <= 64 words;
  header word `{valid, off[19:0], lo_w[10:0], nw[10:0], dh[7:0], dw[7:0]}` (59 bit).  `dh` / `dw` = the most rows / columns the entry can cover
  (plain: its size; zoomed: a dry run of the blitter's source / destination loop of that axis, + 1; 255 = no bound) -- used to cull entries in pass 2.
  Entries that do not fit the 2 MB window are dropped (header invalid).
* **Pass 2** (`jchan_spr_band`): `frame_start` + registers; geometry scan (5 clocks / entry) writes table T; per band a scan over T (2 clocks /
  entry), for a hit: fetch the 3 list words + header, DMA-in, hand over to the blitter when it is free (two blit RAMs ping-pong, so the DMA of the
  next entry overlaps the blit of this one), blit, clean the RAM span.  `late` flags a band that was still being drawn when its first line was
  displayed.
* **Display**: `jchan_video` reads ring line `y mod 32` (port B of the ring RAM) and clears behind the read through the same port.
* **List**: one latched list per chip.  At line 240 pass 2's geometry scan reads it once (everything pass 2 needs later -- sizes, zoom words, flips,
  position, colour / priority -- goes into table T); only then (`geo_done` of both chips, a 40 K clock watchdog) the board copies the live list over
  it and starts pass 1 of the new list.  So pass 1 (during the frame) and the geometry scan (right after the snapshot) share the one read port.
* **Single decode / blit RAMs** (`PINGPONG = 0`, the default): the decoder waits for the store unit to be through with the RAM, the DMA waits for the
  blitter; pass 1 is up to 1.7x slower (<= 285 K clocks of the 1.6 M of a frame), pass 2 loses nothing measurable (slack of the least band 17.5 lines).

## 7. Verification

| bench | checks | result |
|---|---|---|
| `tools/bench_spr_dec.py` (pass 1) | header words and stored words of every entry vs the model's decode, random lists and all 60 dumped real frames x 2 chips, random ROM latency 1..6, store write stalls | PASS |
| `tools/bench_spr.py` (whole chip) | the 320 x 240 picture read out of the ring by a raster model (460 x 261, clear-on-read, pixel clock every 5 .. 12 clocks; the real one is 13.4) vs the model's bitmap, random lists with random latencies and all 60 real frames x 2 chips (and the RTL's own latched lists of the whole-core runs) | PASS, `late` never set |
| `sim/run_snapram.sh` (`jchan_snapram`) | palette-style and plain instance: random CPU writes (byte lanes, held while the scan has not read the entry) around snapshot pulses; the display copy equals the live RAM of the pulse and never changes otherwise; 3 mutations of the hold are caught | PASS |
| `sim/run_core.sh` (whole core) | from reset, through the SDRAM controller and model: CPU memories and pictures vs MAME at (MAME frame N, RTL event N + 1), see below and `cpu_side.md` 4.3 | see below |
| `tools/rtl_selfcheck.py` | the picture the whole core scanned out for event L vs the reference model rendering of the RTL's own dump of that event (tile RAM, palette, registers, latched lists): the video pipeline checked without the CPUs' timing | PASS: 278 of 278 pictures of the jchan (1006 frames), jchan2 and jchana (700) runs, 0 differing pixels |
| `tools/store_check.py` | pass 1 in the whole core: the decoded-sprite store in the SDRAM model and the header RAMs of an event vs the model's decode of the latched list (`+STOREDUMP`) | PASS at jchan2 events 700 / 701 (477 / 466 entries) |

**Found by the whole-core runs (and not by the chip / video benches, whose memory model has no contention):**
* **VIEW2 starved behind the CPUs' cache misses.**  jchan2 frame 700 had 4 isolated sprite pixels missing in one row: the picture of the RTL's own
  state was right (`rtl_selfcheck.py`), the decoded store and header RAMs were exactly the model's (`tools/store_check.py`, run with `+STOREDUMP`),
  and `view2_overrun` had been set since event 684.  A line render of VIEW2 is 84 two-word ROM requests that must all be served within one display
  line (6.2 K clocks); the port order had them behind both CPU caches and the YMZ, and in heavy frames (466 entries, two CPUs missing the cache, sprite
  DMA bursts of up to 64 words in front) a line took up to **9.4 K clocks** (254 lines > 3 K, 23 lines > 5 K of 168 K): a line start that arrives
  while the renderer is busy is dropped, the line shows the previous line's tile data where they differ.  VIEW2 is now port 1 (first after the
  loader): its bandwidth is 84 x ~12 clocks of every 6.2 K, the CPUs lose a few clocks per miss; **longest line 4.3 K clocks, no line > 5 K, no
  overrun**, frame 700 equal to MAME (with the timing-closure RTL's slower geometry stage and the registered strobes: longest line
  3.6 / 4.5 / 3.7 K clocks in jchana / jchan2 / jchan, 0 lines > 5 K, 0 overruns in 700 / 700 / 1006 frames).  The mem unit bench's tile client now idles like the real one (a client that never idles starves everything
  below it) and prints its request latencies: 24 clocks on average, 41 at the most, with the CPUs and both sprite streams saturating the controller.
* Not covered either way: sprite ROM reads beyond the loaded data (chip 2: the 4 MB window is followed by unpopulated SDRAM and then the decoded
  stores; MAME's region reads 0 there): only unused list entries can point there.

## 8. Block RAM, logic and timing on the real device (Quartus 17.0.2 Lite, 5CSEBA6U23I7, `work/quartus/core`)

Analysis & synthesis takes 2 minutes, the fitter 12 (7 GB of memory), core only (the memory controller and loader are not in the project yet,
all 786 ports are virtual pins):

| | |
|---|---|
| ALMs | 11,735 / 41,910 (28 %) |
| registers | 14,345 |
| block memory | 4,528,192 bits of 5,662,720 (80 %), **552 of 553 M10K blocks (100 %)** |
| DSP | 20 of 112 |

The RAM budget was the tightest resource and it just fits.  From the fitter's RAM summary (Kbit): work RAMs 2 x 512, mcuram 512 (`MCU_AW` = 15: the
boot RAM test touches all 64 KB, the games use less than 16 KB), palette live 512 + display copy 272 (17,408 x 16), tile RAM live 128 + copy 128,
shared RAM 128, sprite lists live 4 x 64 + latched 2 x 128, toybox data ROM 192 (24,576 bytes), sprite headers 4 x 59, T tables 2 x 92, rings
2 x 160, decode RAMs 2 x 64, blit RAMs 2 x 32, fx68k micro / nano ROMs 2 x 40, VIEW2 line buffers 2 x 14 -- 4,528 Kbit in 552 of 553 blocks.
What is still on the table if the MiSTer framework (OSD, scaler, I/O) needs blocks: `MCU_AW` = 13 (-384 Kbit), one ring band less
(2 x 40), the toybox ROM at 22 KB.  (The live palette and tile RAM stay complete: the boot RAM test reads every word back.)

**What the synthesis taught** (all in the RTL now, simulation is unchanged):
* A true dual-port RAM with read-first (old data) behaviour is not inferred ("unsupported read-during-write behavior": the RAM became 100 K
  registers and the run did not finish in 50 minutes at 8 GB): `jchan_tdpram` is an explicit `altsyncram` under Quartus (`ALTERA_RESERVED_QIS`),
  same-port read-during-write "don't care" (nothing reads a port's own write clock), mixed-port old data.  The sprite rings are such a RAM
  (port A blitter writes, port B display read + clearing write).
* Byte-enabled single-port RAM from partial writes to a word array is not inferred either: `jchan_spram` is two byte arrays under Quartus.
* A 1-bit array with two writes and a read per clock (the first dirty-mark version of `jchan_snapram`) is three ports: it became registers.
* A RAM read through a mux after the array (`rom_q <= in_window ? rom[a] : 0`, toybox) is "asynchronous read logic": the window is applied after the
  registered read now.

**Timing** at 96 MHz (`mister/quartus/`, `jchan_fit`): **met in all four models, setup and hold, TNS 0** -- setup slack +0.95 ns (slow 1100 mV
100 C) / +0.69 ns (slow -40 C) / +5.4 / +6.2 ns (fast), hold >= +0.10 ns, 11.7 K ALMs, 14.3 K registers, 20 DSP.  It started at -5.3 ns / TNS
-3.3 us; what closed it (`mister/quartus/README.md` has the list): SDC multicycle paths for fx68k's own registers, from its address bus and
function code and from the board's RAM outputs into its data latches (the CPU's registers change only at the phase enables, 3 clocks apart); the
board's RAM write enables registered one clock after the bus cycle's start; the YMZ280B voice in working registers with a four-stage ADPCM step;
the sprite geometry in four stages; the toybox with running addresses; the audio stage and the palette address with a register more.  The memory
controller and the SDRAM pins are not in this analysis (they come with the MiSTer framework; the controller is metro-mister's, hardware-proven at
96 MHz).

**The whole project** (`mister/Jchan.qpf`, the MiSTer framework + `jchan_core` + `jchan_mem`; `docs/mister_top.md` has the table): the core alone's
budget above did not leave room for the framework (586 / 553 blocks at the first fit).  The toybox RAM is 16 KB (`MCU_AW` = 13), the live palette
keeps only the 17,408 entries a pixel can select (`jchan_snapram` PAL = 1: live RAM 17,410 words, the 15,360 unused addresses fold onto two scratch
words by bit 0), the T tables are MLABs: 537 / 553 M10K, 26.7 K ALMs, setup +0.28 ns slow 100 C / +0.055 ns slow -40 C at 96 MHz.  The SDRAM
controller's arbitration is registered one clock ahead and its pins' registers are a stage behind the FSM (`P_RET` = 4, `i_rd_late` adds one).
