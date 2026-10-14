# CPU side: two 68000s, the board's buses, interrupts, toybox (`jchan_sys`, `jchan_board`, `jchan_toybox`, `jchan_core`)

Everything the two 68000s see, in RTL, checked against MAME 0.289 running the real ROMs from reset. Memory map, interrupt model and I/O are
`jchan.cpp`'s (see `hardware.md` sections 3-4); the toybox is `toybox.md`.

| module (`rtl/`) | |
|---|---|
| `jchan_m68k.sv` | one fx68k with a request / acknowledge bus on its far side (`req`, `addr`, `rnw`, `be`, `wdata`, `ack`, `rdata`), autovectored interrupts by level, `iack` pulse |
| `jchan_board.sv` | both address maps, work RAMs, shared RAM (true dual port), mcuram, palette, tile RAM, sprite lists (live + latched), sprite / VIEW2 registers, I/O ports, interrupt latches, watchdog strobe, YMZ280B write port |
| `jchan_toybox.sv` | the MCU stand-in: mailbox, commands 02 / 42 / 03 / 04, 64 KB data ROM window with decrypt-at-load, 93C46 image |
| `jchan_sys.sv` | 2 x `jchan_m68k` + `jchan_board` (+ bus trace outputs) |
| `jchan_cen.sv` | 16 MHz CPU phase enables and the 7.159 MHz dot-clock enable (`jchan_pixgen`: 13 clocks apart, identical lines) from the machine clock |
| `jchan_core.sv` | `jchan_sys` + `jchan_video` + `jchan_cen`; all big memories behind ports |
| `jchan_ram.sv` | `jchan_spram` / `jchan_tdpram` (block RAM style, byte enables) |

## 1. Bus protocol and timing

* CPU side: `req` is combinational (address strobe active, not an interrupt acknowledge, and for a write the data strobes seen); `DTACK = req & ack`,
  `iEdb = rdata`. A slave that is not ready keeps `ack` low (wait states).
* Internal memories are block RAMs addressed straight from the CPU's address bus (stable a CPU clock before AS); `ack` rises in the **second clock of
  the cycle**, so with a 96 MHz / 6 CPU clock there are no wait states, the same as MAME's model. (A first version registered the ack and cost
  ~5 clocks: at the 32 MHz bench clock that inserted wait states and made the RAM-test loops of the boot run slower than MAME's; at 96 MHz it would not have.
  The bench now runs the real 96 MHz / 6 with the CPUs on a gated clock, see 5.)
* The RAMs' write enables are registered strobes: the write happens the clock after the cycle's first (address, byte enables and data are stable for
  the whole cycle; the bus decode + the strobe logic did not fit a block RAM's write-enable setup at 96 MHz).  The mcuram port is the toybox's while it
  runs: its select is a register one clock behind `busy` (the engine has a wait state for it), and the board holds the main CPU's mcuram cycles
  until the toybox is done (reads would otherwise see a command in flight).
* Program ROMs: `mrom_*` (main, 2 MB) / `srom_*` (sub, 1 MB): `req` level, `addr` word address, `ack` one clock (or a level) with `data`; the board holds
  the data for the rest of the cycle. The bench server answers in the same clock; the SDRAM controller will take a few clocks (wait states).
* The mailbox write that triggers a toybox command is held (no ack) until the command is done (`busy`, <= ~1.5 K clocks), so its effect is visible to the
  next access exactly as in MAME.
* Both CPUs take the same phase enables (one 16 MHz crystal on the PCB). The enables keep running during reset: the 68000 needs clocks to take its reset.

## 2. Interrupts (HOLD_LINE)

One latch per level per CPU, set by the event, cleared when that CPU acknowledges that level (`iack` pulse with `eab[3:1]`); the pending level goes to IPL
as the highest set latch. Events (raster: 460 x 261, scanline N starts when the pixel tick that ends line N-1 happens):

| CPU | level | event |
|---|---|---|
| main | 1 | line 240 |
| main | 2 | line 11 |
| main | 3 | the sub CPU writes 400000 / 400001 |
| sub | 1 / 3 / 2 | line 240 / 11 / 249, only while f00000 bit 15 was written 1 |
| sub | 4 | the main CPU writes 403ffe / 403fff |

`f00000-f00007` write: any word, `sub_irq_enable = be[1] & wdata[15]` (MAME's `ctrl_w(u16 data)` takes no mask: with only the low lane active the
bit it sees is 0). Autovector (VPA) for all levels.

## 3. Sprite list latch

MAME copies both lists into the chips' 32-bit buffers at line 240 and draws from the copy at the END of the frame, with the state its vblank handlers
left (one frame late, `rle_sprites.md`).  Here: two banks of 4096 x 16 per chip (even / odd words = low / high halves of the 32-bit sprite word,
`(w[2k+1] << 16) | w[2k]`), copied at line 240 by a 4096-clock engine into the chip's latched list (CPU accesses to the live list RAMs are **held**
while the copy runs, <= 43 us at 96 MHz, so the copy is atomic as seen by the software); `dec_start` fires when it is done (pass 1 of the sprite
chips decodes the list).  The sprite / VIEW2 registers are latched at line 240.  The tile RAM and the palette have display copies
(`jchan_snapram.sv`) that FOLLOW the live RAM from line 240 to line 259 and are frozen from line 260 to line 239 (the CPU is never held for them);
`band_start` fires at line 240 (pass 2 draws the picture of the previous frame's list; the picture is displayed during the next frame).  See `memory.md` 5.

## 4. Verification (MAME as the oracle)

### 4.1 Toybox: `tools/bench_toybox.py` (Verilator, bus-level, replays `work/toybox/<set>.vectors.txt`)

| set | generated cases | real game commands | failing |
|---|---|---|---|
| jchan | 163 | 17 | 0 |
| jchana | 163 | 17 | 0 |
| jchan2 | 163 | 33 | 0 |

The expected bytes are MAME's own results. Negative control (one bit flipped in the data ROM image): fails as it must. Longest command: 1,416 clocks busy.

### 4.2 Two CPUs, from reset, real ROMs: `tools/sys_compare.py` (`tools/lua/sysdump.lua` in MAME, `sim/run_sys.sh` / `run_core.sh` for the RTL)

MAME is run from reset with a fresh EEPROM and idle inputs (P1 / P2 / SYSTEM / EXTRA = ff00, DSW1 = db00, read from MAME), the RTL likewise. At each
dumped frame every CPU-visible memory is compared: main work RAM, sub work RAM, mcuram, shared RAM, both sprite lists (live and as MAME draws them =
latched at the previous line 240), both sprite register blocks, VIEW2 registers and tile RAM, palette. The RTL runs at the real 96 MHz / 6.

| set | frames | result |
|---|---|---|
| jchan | 10 | all regions identical (RAM tests in lock-step) |
| jchan | 20-40 | identical except the memory-test pattern being written at that instant (phase of the tests) |
| jchan | 50-420 (every 10 / 20), CPU side alone and the whole core | **every memory identical except 2-4 bytes of sub work RAM** (a free-running 16-bit counter at 0082-0083, stack residue at efef / efff) |
| jchan | 440-1000 (every 20; the whole core) | VIEW2 / sprite registers, palette, mcuram, shared RAM identical, tile RAM and sprite lists identical except at the dump instants of a burst in progress (below); 4-11 bytes of work RAM (counters) |
| jchan2 | 100-380 | identical except 3-4 counter bytes |
| jchan2 | 400-700 (every 4 / 20; sub CPU interrupts enabled from ~frame 400) | tile RAM, sprite lists and registers, mcuram, shared RAM identical; 5-9 bytes of work RAM (counters one or two counts apart, constant offset from frame 440 on), one palette byte (word 1 = 0007 in MAME, 0000 here) |
| jchana | 100-420 | identical except 3-4 counter bytes; 440-700 as jchan |

**The same writes in the same order**: the control / inter-CPU / toybox writes of a MAME run (`tools/lua/ipc_log.lua`: main 403ffe, f00000-f00007,
330000-360000, sub 400000) against the RTL bench's bus trace: jchan2, 660 writes up to frame 700, **the same sequence, same data**, the same frame
number for 658 of them and one frame later for 2. So the interrupt flow (level 1 / 2 / 3 / 4 with HOLD_LINE, the sub CPU enable) behaves as MAME's.

Two things the comparisons taught:

* MAME's `frame_done` callback (where its dumps are taken) runs right after the screen update, at the start of the vblank (line 240), before the
  level 1 handler of that line; the RTL dumps at its line-240 event.  The frame numbers differ by one (MAME's frame_number() counts from 0, the RTL's events
  from 1): MAME's frame N is the RTL's dump N + 1 (`sys_compare.py` `--shift 1`).  With that pairing the live sprite list, the previous one and every
  other video memory are identical; an earlier comparison paired N with N and read the one-frame offset as differences in the handler's rewrites.
* the counters that differ by 1-2 counts after the sub CPU's interrupts start are timing noise between two 68000 implementations (fx68k is cycle exact, MAME's
  core is approximate), not lost interrupts: the sequences above are equal and every video memory agrees.

### 4.3 Whole core: pictures against MAME's snapshots (`sim/run_core.sh`, `tools/sys_compare.py pic` / `cmp`, `tools/rtl_selfcheck.py`)

Both CPUs + both sprite chips + VIEW2 + mixer + palette at 96 MHz from reset, no reset in between, the ROMs and the decoded-sprite stores in the
SDRAM model behind the real controller, 0 SDRAM timing violations.  MAME's frame N (its `frame_done` dumps and snapshots) is drawn at line 240 of that
frame, which is the RTL's (N + 1)-th line-240 event; the RTL scans that picture out in the next frame (`memory.md` 5).  Pairs are (MAME N, RTL N + 1):

| set | frames run | pictures identical to MAME | the others |
|---|---|---|---|
| jchan | 1006 | 110 of 113 (boot messages, logos, full-screen images, scene changes, scrolling text) | frames 5 - 7 (boot, the video RAM test's colour bars: 324 px; the RTL's CPUs are a few microseconds apart from MAME's there) |
| jchan2 | 700 | **62 of 62** (incl. a palette entry blinking every other frame, a 30 Hz scene, the heaviest frames: 466 entries per chip) | |
| jchana | 700 | 102 of 103 | frame 441: 434 px (the "Check F : Ok" line one frame later, CPU timing, see below) |

CPU memories at the same pairs (`sys_compare.py cmp`): **every video-visible memory (both sprite lists, the latched lists, sprite and VIEW2
registers, tile RAM, palette), the toybox RAM and the shared RAM equal at all dumped frames from frame 42 on**, except frames 440 / 441 of jchan and
jchana (the game state of one frame is reached a few microseconds later than in MAME, below); jchan frame 41: the boot palette test, 2048 B of the
palette; the work RAMs differ in a few bytes (counters, stack residue: <= 25 B, one frame of jchan2 166 B).
VIEW2 never overran in these runs (longest line render 3.6 - 4.5 K clocks of 6.2 K; `memory.md` 7), 0 SDRAM timing violations, `late` never set.
The table is the RTL of the timing closure (`mister/quartus/`, registered strobes, pipelined YMZ / geometry / toybox); the earlier RTL gave the same
pictures and the same memory differences frame for frame, which is what the pipelining had to preserve.
The same results hold for the RTL of the whole-project bitstream (`Jchan.rbf`: 16 KB toybox RAM, compact live palette, pipelined SDRAM arbiter; longest
VIEW2 line 4.0 - 4.3 K clocks, 0 overruns); `sys_compare.py cmp` ignores the bytes the RTL does not keep (`mcu` above 0x4000, `pal` 0x0400-0x3fff words).

**What is left in the pictures is the CPUs' timing, not the video path.**  `tools/rtl_selfcheck.py` renders the RTL's own dump of an event (tile RAM,
palette, registers, latched lists) with the reference model and compares it with the picture the RTL scanned out for that event: **all 278 pictures
of the three runs equal the model of the RTL's own state**, so the pictures above differ from MAME's only where the dumps do (jchana 441: at that line 240 the RTL's main CPU has not yet finished a toybox command's results and the
text it prints; its picture of the next event equals MAME's frame 442 exactly).  Toybox commands take up to 15 us in the RTL and no time in MAME's HLE.

(The first version of this comparison paired MAME's frame N with the RTL's picture N and saw a frame of lag in every frame in which a value changed;
see `memory.md` 5.)

### 4.4 Audio (`sim/run_core.sh +YMZROM= +AUDIO=`, `tools/xcheck/wavcmp.cpp`)

The core's YMZ280B output for the first 16.6 s (first key-on at 11.4 s) against MAME's `-wavwrite` of the same time: **level ratio 1.0020 (0.02 dB)**;
SNR 17-22 dB with the lag of exactly the loader delay of the bench (131,072 clocks = 1.37 ms = 66 samples at 48 kHz). The SNR is limited by the sub-sample
timing of sound starts between two 68000 emulations (a start one 12 us stream sample earlier changes a 5 kHz wave a lot) and by the two resamplers;
the chip itself is checked sample by sample in `docs/sound.md`.

## 5. Simulation speed

fx68k is expensive in Verilator (~3 us per clock). The bench runs the real 96 MHz / 6 timing; `SIM_GATE=1` in `jchan_m68k` gives each fx68k a gated clock
that only ticks in the clocks that carry a phase enable (latch-based gate), so the simulator evaluates the CPUs 3x less. The gated and the plain-enable
runs are bit-identical (frame 10 dumps compared). ~3-5 s per emulated frame for the whole core (CPUs + both sprite chips + VIEW2): 1000 frames in
~85 min; the CPU side alone is a little faster.

## 6. Not done / open

* **Watchdog**: writes are accepted and strobe `wdog_kick`; no timeout reset (MAME's watchdog would reset the machine if the game stopped kicking).
* **Wait states**: with the SDRAM controller in the path ROM reads miss the line caches now and then (~10 clocks, 1 - 2 CPU clocks; MAME and probably the
  PCB have none); the whole core from reset still matches MAME's memories (`memory.md` 4).
* **EEPROM**: the toybox keeps the 93C46's 64 words in registers (`nv_*` ports to load / read back); MiSTer's save mechanism is not wired.
* The tile RAM / palette / VIEW2 registers of a picture are MAME's state at the end of the frame (`jchan_snapram`, follow / freeze); the hardware
  probably reads them live while it scans, and whether a game's mid-frame writes show tearing there is unknown.
* The sub CPU runs from reset (as MAME); whether the board holds it until main sets f00000 bit 15 is unknown.

## 7. `jchan_core` ports (what the MiSTer top and the memory controller connect)

| group | ports | notes |
|---|---|---|
| clock | `clk` (96 MHz), `rst` | CPUs 96 / 6 = 16 MHz, dot clock 7.159 MHz as a regular 13-clock enable (`jchan_cen` / `jchan_pixgen`), sound tick 96 MHz / 1152 |
| program ROMs | `mrom_*` (main, 2 MB, 20-bit word address), `srom_*` (sub, 1 MB, 19-bit) | `req` held until a one-clock `ack` with `data`; an answer within ~8 clocks costs no CPU wait state |
| toybox | `ld_*` (the 128 KB data ROM streamed once, MAME region order, undecrypted), `nv_*` (93C46 image load / read-back, `nv_saved` pulse after command 42) | |
| inputs | `in_p1`, `in_p2`, `in_sys`, `in_extra`, `in_dsw1` | `jchan_io` makes them from joysticks / buttons (MAME's active-low words, 3+1 / 2+2 layout, coin stretch) |
| sprite ROMs | `rom1_*` (SPA, 22.5 MB byte stream), `rom2_*` (SPB, 4 MB byte stream) | ready / valid in-order protocol of `jchan_rle` (`docs/rle_sprites.md`) |
| tile ROM | `v2rom_*` | 32-bit words of `jc-200-00` (1 MB) |
| sprite stores | `st1_*` / `sr1_*`, `st2_*` / `sr2_*` | per chip: write port (pulled words) and read port of the decoded-sprite store in the SDRAM (`memory.md` 3) |
| sample ROM | `ymz_rom_*` | 24-bit byte address into the 16 MB region (3.25 MB populated, zeros above 0x440000) |
| audio | `audio_*` (83.33 kHz, 16 bit + 28-bit sums), `audio48_*` (48 kHz) | |
| video | `o_ce`, `o_x`, `o_y`, `o_de`, `o_hs`, `o_vs`, `o_r/g/b`, `o_idx` | 320 x 240 visible of 460 x 261; sync positions are placeholders |
| status | `m_halted`, `s_halted`, `irq_sub_en`, `spr_busy`, `spr_late`, `view2_overrun`, `ev_l240_o` | |
