# Kaneko Jackie Chan board (jchan / jchana / jchan2) -- hardware map

Source: MAME 0.289 `src/mame/kaneko/jchan.cpp` (+ `kaneko_rlespr.cpp`, `kaneko_tmap.cpp`, `kaneko_toybox.cpp`), pinned in `ref/mame/`. Nothing here is
measured on a PCB except what the driver's own header says. Items marked **VERIFIED** were checked against MAME running the real ROMs
(`tools/jchan_frame.py`, `tools/xcheck_rlespr.py`); **MAME** = taken from the driver, not independently confirmed; **UNKNOWN** = the driver says
it does not understand it.

## 1. Sets

| set | title | parent | notes |
|---|---|---|---|
| `jchan` | Jackie Chan - The Kung-Fu Master (rev 4?) | | main set |
| `jchana` | same (rev 3?) | jchan | different main / sub program + MCU data ROM; everything else shared |
| `jchan2` | Jackie Chan in Fists of Fire | | same PCB; different programs, portrait ROMs (2 x 512 KB), sound ROM, MCU data |

All ROT0, 320 x 240. DIP "Buttons Layout" (SW1:8) 3+1 / 2+2 changes how `P1/P2/EXTRA` bits are read (jchan2 ignores it).

## 2. Clocks and video timing (MAME)

| | |
|---|---|
| 68000 main, 68000 sub | 16.000 MHz each |
| YMZ280B | 16.000 MHz (MAME's chip model: voice clock = clock / 384 = 41,666.7 Hz; its stream runs at twice that, 83.3 kHz) |
| pixel clock | 28.636363 MHz / 4 = 7.159 MHz |
| raster | 460 x 261 total, 320 x 240 visible -> 59.629 Hz (PCB notes: 59.6010 Hz, HSync 15.5561 kHz) |
| PCB crystals | 28.6364 MHz, 16 MHz, 33.3333 MHz (the sprite generators' clock?) |

## 3. Memory maps (MAME)

### Main 68000
| address | size | what |
|---|---|---|
| 000000-1fffff | 2 MB | program ROM (4 x 512 KB, interleaved: u67/u68 low 1 MB, u69/u70 high 1 MB) |
| 200000-20ffff | 64 KB | work RAM |
| 300000-30ffff | 64 KB | `mcuram` -- the MCU's shared RAM (the game keeps its DSW at 300200, cmd words at 300010-300014) |
| 330000 / 340000 / 350000 / 360000 | W | toybox `mcu_com0..3` (see section 6) |
| 370000 | R | toybox status (always 0) |
| 400000-403fff | 16 KB | shared RAM with the sub CPU |
| 500000-503fff | 16 KB | sprite list of chip 1 (1024 entries, `docs/rle_sprites.md`) |
| 600000-60003f | 64 B | sprite registers of chip 1 |
| 700000-70ffff | 64 KB | palette RAM, 32768 words xGRB555 (G = bits 14:10, R = 9:5, B = 4:0) |
| f00000-f00007 | | R: P1, P2, SYSTEM, EXTRA; W (f00000): bit 15 = sub CPU interrupt enable (the driver's "hack / guess!") |
| f80000 | | watchdog |

### Sub 68000
| address | size | what |
|---|---|---|
| 000000-0fffff | 1 MB | program ROM (2 x 512 KB) |
| 100000-10ffff | 64 KB | work RAM |
| 400000-403fff | 16 KB | shared RAM with the main CPU |
| 500000-503fff | 16 KB | VIEW2 tile RAM: 0000 vram_1 (FG), 1000 vram_0 (BG), 2000 scroll_1, 3000 scroll_0 (docs in `tools/jchan_tiles.py`) |
| 600000-60001f | 32 B | VIEW2 registers |
| 700000-703fff | 16 KB | sprite list of chip 2 |
| 780000-78003f | 64 B | sprite registers of chip 2 |
| 800000-800003 | | YMZ280B, low byte only (address, data) |
| a00000 | | watchdog |

### Inter-CPU protocol (MAME comments; the games' own convention)
main -> sub: main clears `400002`, writes the command word to `403ffe` (raises sub IRQ 4), polls `400002` until non-zero (0xffff = done);
parameters `403c02/04/06`, result `400004`. sub -> main: writing `400000` raises main IRQ 3 (MAME: "is this called?").

## 4. Interrupts (MAME, "NOT understood" -- jchan2 crashes in MAME if the order is wrong)

| CPU | level | when |
|---|---|---|
| main | 1 | scanline 240 (vblank start; also the instant MAME copies both sprite RAMs, see rle_sprites.md) |
| main | 2 | scanline 11 |
| main | 3 | the sub CPU's write to 400000 |
| sub | 1 / 2 / 3 | scanline 240 / 249 / 11 -- only while main's f00000 bit 15 is set |
| sub | 4 | the main CPU's write to 403ffe |

All are HOLD_LINE (the line stays until the CPU acknowledges). The sub CPU runs from reset in MAME; whether the real board holds it until bit 15
is set is not known.

## 5. Video (all VERIFIED against MAME, 26 real frames, pixel-identical)

Final pixel (`jchan.cpp screen_update`): background index 0x7f00; the 8 tile categories are drawn in order (BG then FG per category); then the two
sprite bitmaps are mixed per pixel by their 2-bit priority against the tile's category >> 1 -- see `tools/jchan_spr.py mix()`, a literal port.
Palette index of a sprite pixel is `0x4000 | colour << 8 | pen`; of a tile pixel `colour << 4 | pen` (colour = attr[7:2]).

* **Tiles**: `tools/jchan_tiles.py` (header comment is the register / RAM spec). 16 x 16 x 4bpp, ROM tile = 128 B: four 8 x 8 blocks TL TR BL BR,
  4 bytes per pixel row, the left pixel of a byte pair in the LOW nibble. FG layer has 2 more pixels of x offset than BG (35 vs 33).
  Screen flip (regs[4] bits 9/8) is not modelled (jchan's flip DIP).
* **Sprites**: `docs/rle_sprites.md`.
* **Timing of the data**: MAME draws at the start of the vblank (line 240): tile RAM, tile registers, palette and sprite *registers* are those of
  that line; the sprite *lists* are the copy made at line 240 of the previous frame. VERIFIED: fight frames match only with the previous frame's lists.

## 6. Toybox MCU (MAME HLE of a NEC uPD78324 "TBS0P01", internal ROM never dumped)

Full behavioural spec, byte-order details and RTL test vectors, all checked against MAME running the real ROMs: **[toybox.md](toybox.md)**.
Summary:

Registers (68000 side): four write-only words `330000 340000 350000 360000`; the command executes when all four hold 0xffff (then they clear).
Parameters live in `mcuram`: `+10` command (high byte), `+12` destination byte offset in mcuram, `+14` sub-command. Status read returns 0.

| cmd (high byte) | action |
|---|---|
| 02 | load 128 B from the 93C46 (64 words, big-endian) to mcuram[dest] |
| 42 | store 128 B from mcuram[dest] to the 93C46 |
| 03 | mcuram[dest] = the DSW1 port word (DIP bank SW1, bits 15:8; the game finds it at 300200 and copies it to 200098) |
| 04 | protection data: entry `(sub & 0x3f) * 8` of the directory at `mcudata[0x10000]` = {unused16, src16, len16, extra16} (little endian over MAME's byte-swapped, decrypted image); copy `len` bytes of `mcudata[0x10000 + src ..]` to the 68000 bytes `dest ...` (original order for even `src` / `dest`) |
| 43 | only Bonk's Adventure; ignored by jchan |

`mcudata` (128 KB, `jcd0x2.u13`, WORD_SWAP) is "decrypted" at start: `b[i] += table[(i ^ 1) & 0xff]` (256-byte `decryption_table`,
`kaneko_toybox.cpp`). jchan uses `GAME_NORMAL`, `TABLE_NORMAL`. The game checks a build string in the EEPROM image and an MCU answer
("1995/05/24 The kung-Fu Master Jackie Chan" / "1995/10/24 Fists Of Fire").

EEPROM: AT93C46 in 16-bit mode (64 words); no default image in the driver (starts erased; the game formats it through cmd 42).
For the RTL: `metro-mister/mister/rtl/metro_eeprom.sv` is a 93C46 already written from MAME's behaviour; here the 68000 never talks to the
EEPROM -- only the toybox does (cmd 02/42), so a plain 64-word RAM with a load/store engine is enough.

## 7. Sound

YMZ280B, 16 MHz, stereo (two outputs to the front L/R, gain 1.0). DIP SW1:4 "Sound" mono / stereo is read by the game, not the chip.
Sample ROM: `jc-301-00` (1 MB, loaded twice: 0 and 0x100000), `jc-300-00` (2 MB at 0x200000), a 256 KB EPROM at 0x400000 (`jcw0x0` / `j2m1x1`);
the region is 16 MB, ~3.25 MB unique.
RTL: `rtl/jchan_ymz280b.sv`, written from MAME's `ymz280b.cpp` (the Cave core's YMZ280B was not used) and verified sample for sample against MAME's own
chip code; see **[sound.md](sound.md)**. Output 83.33 kHz (MAME's stream rate), `rtl/jchan_audio48.sv` brings it to 48 kHz.

## 8. ROM data (bytes, VERIFIED CRC with `tools/jchan_rom.py`)

| region | size used | notes |
|---|---|---|
| maincpu | 2 MB | |
| sub | 1 MB | |
| spritegen1 (SPA) | 22.5 MB (0x1680000; 0x1600000 + 2 x 256 KB, jchan2: 2 x 512 KB) | chip 1; MAME region is 32 MB |
| spritegen2 (SPB) | 4 MB | chip 2; MAME region is 16 MB |
| view2 | 1 MB | `jc-200.00`, 8192 tiles |
| ymz | 3.25 MB unique (1 + 2 + 0.25) | |
| mcudata | 128 KB | |
| total | ~33.9 MiB | does not fit a 32 MB SDRAM module -> 64 MB (the `metrof64` path of metro-mister) |
