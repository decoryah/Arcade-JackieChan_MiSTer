# The MiSTer top (`Jchan.sv`, `Jchan.qpf`, `mra/`)

`Jchan.sv` is the `emu` module of the MiSTer framework (`sys/`, copied unchanged from metro-mister / taitol-mister: the five cores of the
owner carry the same framework files).  It wraps the verified `jchan_core` (both 68000s, board, toybox, VIEW2, both sprite chips, YMZ280B) and
`jchan_mem` (the SDRAM controller, the client adapters, the loader) and does the platform's part:

| | |
|---|---|
| clocks | `rtl/pll.v`: 50 MHz -> 96 MHz machine clock + the same clock shifted -5078 ps for the SDRAM chip's pin (the phase and the SDC's two-cycle read-capture path are those of metro-mister / taitol-mister, hardware-proven with the same controller physical layer) |
| ROM stream | MRA index 0, 0x2350000 bytes, see below; remapped on the fly into the SDRAM image of `docs/memory.md` |
| DIP | MRA index 254, one byte = MAME's DSW1 (SW1:1-8, default 0xDB) -> `jchan_io` / the toybox command 03 |
| inputs | MiSTer joystick 1 / 2: directions, buttons 1-4 (`J1`; the MRA names them Weak Punch, Strong Punch, Weak Kick, Strong Kick, the driver's own words), start, coin; keyboard 1 / 2 start, 5 / 6 coin, 9 service, F1 / F2 test, T tilt (MAME's defaults); coins are stretched to 3 frames by `jchan_io` (MAME's `PORT_IMPULSE(2)`) |
| NVRAM | MRA index 2 (`<nvram index="2" size="128"/>`): the 93C46's 64 words as 128 bytes, little-endian words.  Loaded into the toybox's EEPROM array before the game runs; one second after the game's command 42 stored it (`nv_saved`) the HPS is asked to read it back (`ioctl_upload`) |
| audio | `jchan_audio48` (YMZ280B's 83.33 kHz, averaged to 48 kHz) -> `AUDIO_L/R`, volume option (normal, -6, -12, +6 dB) |
| video | `jchan_video`'s raster (460 x 261, 320 x 240 picture, 7.159 MHz dots = exactly 13 clocks apart, 59.63 Hz, see "The pixel enable") -> `arcade_video` (scandoubler options, aspect ratio) with the standby raster while the machine is held (`jchan_standby`) |
| reset | `status[0]` / OSD Reset / `RESET` / buttons; the machine is also held while an image streams in and until the SDRAM is initialised |

## Testing the NVRAM on the DE10-nano

MiSTer keeps arcade `<nvram>` files in `/media/fat/config/nvram/<MRA file name>.nvm` (128 bytes here).  The game's own first save (command 42 at
boot, after ~7 s, found by MAME capture, `work/toybox/<set>.vectors.txt`) is the expected file of a fresh boot; the core asks the HPS to read it
back one second later (`ioctl_upload_req`):

| offset | content |
|---|---|
| 0x00 | `8B E0 8E 71` |
| 0x04 | ASCII `95/05/24 Jackie ChanVer 1.20` (jchan, jchana) or `95/11/28 Jackie ChanVer 2.31` (jchan2) |
| 0x20 | `00 01 01 01 01 00 03 10 10 28 02 01` (the game's default settings), then zeros |
| 0x7F | `62` (jchan, jchana) / `66` (jchan2) |

**Hardware, 2026-10-13: the save path works** -- the files the DE10-nano wrote for jchan (rev 4) and jchan2 are 128 bytes and byte-identical to the game's first save captured from MAME, and a setting changed in the game's test menu survives a reload of the MRA (the load path, `nv_dl` -> the toybox's 93C46 array, works too).

Test: no `.nvm` for the MRA, load it, wait ~15 s (open the OSD once if the file does not appear), check size 128 and the bytes above; change a
setting in the game's test mode (Test key), check that bytes at 0x20 and 0x7F changed; reload the MRA and see the setting kept.  A file the game
does not recognise (no version string) is simply formatted again at boot.

## The ROM stream (MRA index 0)

The SDRAM image (`tools/jchan_sdram_image.py`) has two big gaps (0x740000-0xFFFFFF and 0x2800000-0x2FFFFFF) that would only waste the HPS's
time, so the MRA stream is the image without them and `Jchan.sv` adds the offsets while the bytes arrive:

| stream | length | what | SDRAM |
|---|---|---|---|
| 0x0000000 | 0x200000 | maincpu (4 x 512 KB, byte-interleaved pairs) | +0 |
| 0x0200000 | 0x100000 | sub 68000 program | +0 |
| 0x0300000 | 0x100000 | VIEW2 tile ROM | +0 |
| 0x0400000 | 0x340000 | YMZ280B samples, MAME region 0x000000-0x0fffff, 0x200000-0x3fffff, 0x400000-0x43ffff (the mirror at 0x100000 is folded away) | +0 |
| 0x0740000 | 0x1800000 | sprite chip 1 ROM (SPA), 24 MB window, zero-padded after the 22.5 MB of files | +0x08C0000 (SDRAM 0x1000000) |
| 0x1F40000 | 0x400000 | sprite chip 2 ROM (SPB) | +0x10C0000 (SDRAM 0x3000000) |
| 0x2340000 | 0x010000 | toybox data ROM, upper 64 KB of `jcd...u13` (the lower half is never read) | block RAM, `ld_addr = {1, i[15:1], ~i[0]}` (MAME's `ROM_LOAD16_WORD_SWAP`) |

`tools/make_mra.py` writes the three MRAs (jchan, jchana in `_alternatives`, jchan2) from MAME's `ROM_START` lists and `-listxml`'s DIP
switches; `tools/mra_verify.py` assembles every MRA's stream from the merged zips exactly as the MiSTer's loader does (`tools/mra_build.py`,
GPL-3.0 from plasticbugs/analogue-pocket-gaiapolis, the same file metro-mister uses), applies the address map of `Jchan.sv` and compares it with
the SDRAM image the simulations ran on (and the toybox window with MAME's `mcudata` region): all three identical.

## The pixel enable (`rtl/jchan_cen.sv`: `jchan_pixgen`; `jchan_standby` uses the same)

The dot clock 28.636363 / 4 = 7.159 MHz is not an integer division of 96 MHz (13.41 clocks).  What the framework's direct video (DV1) gives a
RetroTINK 4K is the raw 96 MHz stream (`HDMI Custom (5686x263p)`: DE synthesised by `sys_top.v` from HS / VS and `ce_pix`), so the pixel edges and
the line lengths are what the scaler locks to.  Three builds, tried on the RT4K (CRT and the framework's scandoubler were fine with all of them):

| build | pixel enable | RT4K DV1 |
|---|---|---|
| 20261013 | numerically controlled: 13 or 14 clocks apart, a different pattern on every line, the pattern's phase moving ~0.4 clock per line against HSync (left edges of text rows walked ~1.3 clocks per line) | very shaky |
| 20261013a | exactly 13 clocks apart, the same pattern in every line; the fraction of the line (6168.4 clocks) spread over the lines outside the vertical sync, so the line alternates 6168 / 6169 clocks | better, still shook a bit |
| 20261013b | as `a`, but **every line is exactly 6168 clocks**; the fraction of the whole frame (261 x 0.381 = 99.4 clocks, carried over the frames: 99 or 100) goes to one line in the vertical blanking, `LONG_LY` = 255 (the SNES has long / short lines the same way) | steady |

What `b` (the current `jchan_pixgen`) does:

* dots are exactly `DOT` = 96 MHz / 7.159 MHz = **13** clocks apart (320 picture + 140 blanking dots of the 460 per line);
* the line is `LINE_I` = 6168 clocks: 460 x 13 = 5980 clocks of dots and a 188-clock idle gap at the start; line 255 is 6267 or 6268 clocks;
* the frame is 261 lines as before: the average line time, the frame rate (59.63 Hz) and the CPUs' clocks per frame are unchanged;
* cost: the active picture is 320 x 13 = 4160 clocks instead of 4291, ~3 % narrower on a CRT (blanking is wider by the difference).

Checked: iverilog (all lines 6168 except line 255, spacing 13..13, first dot at clock 188, 460 dots in every line), `work/csync_model3.py` (the
framework's csync output is the same in every frame), the three whole-core runs (pictures as before: jchan 110/113, jchana 102/103, jchan2 62/62,
self-check 0 pixels), the bench of the top (jchan2: ROM load byte-exact, frames 100 and 120 identical to MAME), the fit and timing; on the RT4K by
the owner (steady).

## Fast load, CRT Adjust, Scale (ported from the owner's Metamorphic Force core)

**Fast load** (`rtl/jchan_fastload.sv`, `Jchan.sv` "Fast load", `address="0x32000000"` on the MRA's index-0 `<rom>`).  A recent Main_MiSTer
assembles the whole 37 MB stream in the DDR3 at that address in one go and then ends a download that has no data bytes, only a start address:
the image's length (an ordinary download has ioctl_addr 0 there).  The core stays in reset from that moment; `jchan_fastload` reads the image
back (256-byte blocks, one 32-beat burst each, into a 32 x 64-bit MLAB buffer) and plays the bytes into the loader as the HPS would have
streamed them, one a clock when the loader does not ask to wait: the remap, the toybox window and the nvram / DIP downloads are unchanged.
The loader's SDRAM writes (about 3.5 clocks a byte) set the time: 130 M clocks = **1.4 s** at 96 MHz, against the HPS port's byte-at-a-time
stream (37 MB: about a minute, estimated from Metamorphic Force's 17 MB in 23 - 25 s).  An older Main_MiSTer ignores the attribute and streams
as before (one core file and one set of MRAs serve both).  Bench: `sim/run_emu.sh +FAST=1` (the stand-in `hps_io` announces the length, a DDR3
model with random busy / latency / bubbles serves the beats): the SDRAM holds exactly the reference image (VERIFY: 0 mismatching bytes).

**Scale** (`status[34:32]`: Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+).  The framework's `video_freak` sits behind
`arcade_video`; it measures the finished picture and turns Aspect ratio + Scale into VIDEO_ARX / ARY (bit 12 set: the exact size in pixels the
HDMI scaler should give).  Full Screen with an integer Scale uses the screen's own proportions (`HDMI_WIDTH / HEIGHT`) so that the result is the
largest whole-number size in the screen's aspect.  Analog output unaffected; Normal as before.

**CRT Adjust** (`status[14]` On / Off, H-Size `[19:15]`, H-Position `[27:21]`, V-Shift `[39:35]`; rmonic79's `modules/crt-adjust`, GPL-3.0+, one
line fixed locally, `modules/VENDOR.md`).  The picture goes through a ping-pong line buffer (3 M10K) and is read out at a different pixel
rate (H-Size) or a different place in the line (H-Position, content shift: the sync pulses stay native), and the vertical sync is delayed by whole
lines (V-Shift), so the monitor stays locked.  For this raster (460 dots a line, the picture 320 of them, hsync dots 340 - 371):
H-Size 0 .. +6 and -16 .. -1 (one step is 1/104 of the pixel period, about 3 pixels of the 320; +6 is the most that fits before the
hsync), H-Position 0 .. +20 and -48 .. -1 pixels, V-Shift -16 .. +15 lines.  The read enable is an accumulator in eighths of a clock
(104 + H-Size per pixel) restarted on the module's line reference.  Off, the picture takes the path it always had (one more register stage);
it does nothing with the scandoubler (31 kHz); with it On the HDMI picture follows it, and the direct video's pixels are no longer a regular
13 clocks (use it Off on the RT4K).  The values are hidden in the menu while it is Off (`status_menumask` bit 1).
Zero position: the module counts the 460 written dots from the hsync, but a line is 6168 clocks (460 x 13 + the 188-clock gap), so on its
read grid the picture would sit 14.46 dots early: `CRT_HBIAS` = +13 (-1 for the module's own delay, +14 for the gap) puts On at zero within
6 clocks of Off; the sync-to-picture distance is 17 lines in both (V-Shift base 0).

| bench run (jchan2, frame ~100) | hs -> first pixel | picture row length | vs -> first row |
|---|---|---|---|
| CRT Adjust Off | 1748 clocks | 4160 clocks (320 x 13) | 17 lines |
| On, H-Size 0, H-Position 0, V-Shift 0 | 1742 | 4160 | 17 |
| On, H-Size +2, H-Position +10, V-Shift +3 | 1908 (144 read pixels x 13.25) | 4240 (320 x 13.25) | 20 |
| On, H-Size -16, H-Position -48, V-Shift -16 | 946 (86 x 11) | 3520 (320 x 11) | 1 |

In all four the 320 x 240 picture is pixel-identical to the core's own (and so MAME's), 240 rows, 320 pixels a row.
Scale at 1080p (`+HDMIW=1920 +HDMIH=1080`, Aspect Original): V-Integer and HV-Integer both ask for 1280 x 960 (4x; 320 x 240 is 4:3); Aspect
Full Screen + HV-Integer asks for 1600 x 960 (5x by 4x, the whole-number size nearest the screen's 16:9).

## Block RAM, logic and timing of the whole project (Quartus 17.0.2 Lite, `quartus_sh --flow compile Jchan`, 5CSEBA6U23I7)

The framework takes ~385 Kbit in ~55 blocks (the scaler's line buffers, the OSD, the scandoubler); the core alone was 552 of the device's 553 M10K
blocks, and the first fit of the whole project said **586 / 553** (with `MCU_AW` = 13 and the adaptive scaler already out).  What brought it under:

| change | blocks | notes |
|---|---|---|
| toybox / MCU RAM 64 KB -> 16 KB (`MCU_AW` = 13, `jchan_board.sv`) | -48 | `tools/lua/mcuram_extent.lua`: after the boot RAM test (5555 / aaaa by word parity, passes aliased) nothing at or above 0x4000 is touched in 90 s of play of any of the three sets |
| `MISTER_DISABLE_ADAPTIVE` (`Jchan.qsf`) | -1 | the scaler's polyphase memory |
| live palette: only the 17,408 selectable entries are kept; the other 15,360 words alias onto two scratch words by address bit 0 (`jchan_snapram.sv`, PAL = 1) | -28 | `tools/lua/palextent.lua`: after the boot test nothing in 0x0400-0x3fff is read or written |
| toybox data ROM window 24 KB -> 22 KB | -2 | the last byte read is 0x556e |
| sprite T tables (92 bits x 1 K) in MLABs (`jchan_spr_band.sv`) | -20 | wide and shallow: a 16:1 read mux; costs ~4 K ALMs |

(The toybox ROM in MLABs was tried first and failed timing by 4.9 ns: 24 K x 8 needs a 384:1 read mux.)

**Result** (`releases/jchan_20261014.{rbf,fit.summary,sta.summary,corners.txt}`, with fast load, Scale and CRT Adjust; seed 2):
28,269 ALMs (67 %), 35,718 registers, **540 / 553 M10K (98 %)**, 49 DSP; setup slack at 96 MHz **+0.296 ns slow 100 C, +0.145 ns slow -40 C**,
+4.96 / +5.78 ns fast; hold >= +0.037 ns (fast -40 C); TNS 0 -- **all four models met**.  The same RTL without the three features
(20261013b, the first build tried on hardware, not published) had 27,196 ALMs, 537 M10K, +0.160 / **-0.009** / +5.02 / +5.73 ns, so
the extra logic landed in a better placement, not a worse one.  Earlier history: 20261013 (the first fit) 26,699 ALMs, 537 M10K, +0.28 /
+0.055 ns slow; 20261013a +0.214 / +0.033.  `quartus/sta_corners.tcl [revision]` runs the four models (the compile's own analysis is the slow
100 C one only).

What it took (the first fit was **-9.2 ns**, 4,000 failing endpoints, because the controller and the adapters had never been through the fitter):
* `jchan_sdram`: the arbitration (11-port priority, the `addr[25*sel +: 25]` slice that became a DSP multiplier, the command mux) was one 20 ns
  combinational path.  The winner is now chosen one clock ahead from the requests and the bank timers as they will be after the edge, and
  registered; the pins' registers sit a stage behind the FSM (`P_RET` = 4).  Memory bench: same latencies (tiles 24.4 clocks average), 0 violations.
* `jchan_ymzrd`: address fold / compare registered; cache and YMZ line addresses are ORs where the offset cannot carry.
* the input words are registered in the top; `Jchan.qsf` uses metro-mister's extra-effort fitter settings (physical synthesis EXTRA, router timing
  MAXIMUM, placement effort 2).

## What the bench of the top proves (`sim/run_emu.sh`, `tb_jchan_emu_top.sv`, `emu_stubs.sv`)

The real `emu` module runs with behavioural stand-ins for the framework's `pll`, `hps_io` and `arcade_video` only; the "HPS" plays the MRA's
ROM stream (`tools/mra_build.py`), the DIP byte and (optionally) an nvram file, honouring `ioctl_wait`.  After the 37 MB stream the SDRAM model
holds **exactly** the simulated image in every loaded window (0 mismatching bytes: the loader, its address remap, the 64 MB controller), the machine
is released, boots, and the pictures of frames 100 and 120 of jchan2 are pixel-identical to MAME's snapshots (62 pictures of the whole-core bench
run the same RTL without the top).  Since 20261014 the bench also plays the fast load (`+FAST=1`: a DDR3 model with random busy, latency and bubbles; the ROM image is loaded
in 130 M clocks, 1.4 s at 96 MHz, 0 mismatching bytes), takes the OSD's status word (`+STATUS=<hex>`), the HDMI size (`+HDMIW` / `+HDMIH`),
runs the framework's `video_freak` for real and captures the finished video (`+VSNAPS`, `tools/vga_check.py`).  Not covered: the framework
itself (scandoubler, scaler, OSD, `hps_io`'s real handshake timing), the PLL, the SDRAM pins at real timing.

## Not done / only on hardware

* Screen flip (the DIP "Flip Screen"): the sprite chips flip, VIEW2's flip bits are not modelled (they are not in the reference either).
* The HSync / VSync positions are placeholders (hs dots 340-371, vs lines 244-246 of 460 x 261; only the totals and the picture are MAME's;
  CRT Adjust moves the picture within them).
  The PCB's measured 15.556 kHz / 59.60 Hz are within 0.05 % of the generator's rate (see "The pixel enable").  No CRT Adjust option yet.
* Direct video (RetroTINK 4K DV1): steady since 20261013b (see "The pixel enable"); other scalers / `csync` settings untried.
* SDRAM read-capture phase (`O[20]`, "SDRAM read capture: Normal / Late"): the default (Normal) works on the owner's DE10-nano; "Late" is untried.
* Hardware status (owner, 2026-10-13, build 20261013b): all three sets run, video / audio / long play good, DIP switches work, nvram saves and reloads,
  CRT fine, RT4K DV1 steady.  2026-10-14, build 20261014: fast load, Scale and CRT Adjust work.
* The watchdog (writes are accepted and ignored).
