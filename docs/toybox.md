# Kaneko "toybox" MCU (TBS0P01, NEC uPD78324) -- behavioural spec and test vectors

The board's MCU firmware was never dumped; MAME 0.289 (`kaneko_toybox.cpp`) replaces it with a small command interpreter that works for
these games. This document is that interpreter, written from MAME's code **and checked against MAME itself running the real ROMs**
(`tools/toybox_model.py` is the executable form; `tools/toybox_vectors.py` makes and checks the vectors). Nothing is known about the real
firmware beyond "the games accept this".

**Verification state** (all three sets, `jchan`, `jchana`, `jchan2`): the model reproduces MAME on 163 generated cases per set (every byte of the
64 KB shared RAM compared after each case) and on every command a boot + game start issues (17 / 17 / 33 commands, whole RAM before and after).
Zero mismatches. Rerun: section 7.

## 1. Interface (main 68000 only; the sub CPU never touches it)

| address | access | |
|---|---|---|
| 300000-30ffff | R/W | shared RAM, plain 64 KB RAM, 16-bit |
| 330000, 340000, 350000, 360000 | W | mailbox words 0..3 |
| 370000 | R | status; always 0 (VERIFIED, also the byte reads). The boot code loops `until (status & 1) == 0` |

* Writes to a mailbox word merge under the bus byte mask (`move.b` to the two halves of a word works).
* When all four words hold 0xffff the command runs and the four words are cleared. Anything less is remembered (VERIFIED: three 0xffff, a read of
  the status, then the fourth runs it; a 0xfffe in a word, rewritten later with 0xffff, runs it; a word written with 0 drops its ffff;
  four high bytes only = nothing). The games write the words in the order 2, 3, 0, 1.
* The command runs instantly (the whole effect is visible to the next bus access).

## 2. Commands (parameters in the shared RAM, 68000 byte order)

```
ram[0x10..0x11]  command word, only the high byte counts (cmd word 04ff == 0400)
ram[0x12..0x13]  destination byte offset  `dest`
ram[0x14..0x15]  sub-command (cmd 04 only; the games leave stale values for the others)
```

| high byte | action |
|---|---|
| 02 | **load**: the 93C46's 64 words -> 128 bytes at `dest & ~1`. EEPROM word `w` appears as the 68000 word with its two bytes swapped (`swap16(w)`) |
| 42 | **save**: 128 bytes at `dest & ~1` -> the 93C46, each 68000 word byte-swapped back (a save followed by a load is the identity) |
| 03 | **DIP**: the 16-bit DSW1 port value (SW1:1-8 in bits 15:8, bits 7:0 = 0) -> the word at `dest & ~1` |
| 04 | **data**: entry `n = sub & 0x3f` of the directory: `{unused16, src16, len16, extra16}` at data-ROM byte `0x10000 + n * 8` (little endian in the decrypted ROM image); `len` bytes starting at data-ROM byte `0x10000 + src` are copied to the 68000 bytes `dest ... dest + len - 1` **in their original order** when `dest` and `src` are even (see 3) |
| 43 | Bonk's Adventure only: ignored |
| anything else | nothing happens (VERIFIED for 00 01 05 06 10 43 44 82 83 ff) |

"Odd" parameters (VERIFIED): `dest` odd for 02 / 42 / 03 is rounded down; for 04 it is used as is (byte copy to `(dest + x) ^ 1`, so an odd
`dest` swaps the byte pairs of the result). `dest + len` must stay inside the RAM (MAME writes past its array otherwise; the vectors stay inside).

## 3. The one subtle thing: MAME's byte indexing

MAME holds the shared RAM as an array of 16-bit values and some code casts it to bytes. On the little-endian (x86) host the oracle runs on, C++
byte index `i` is the 68000 byte at address `i ^ 1`. The data ROM image MAME works on is (a) loaded `ROM_LOAD16_WORD_SWAP` (region byte
`i` = file byte `i ^ 1`) and (b) "decrypted" in place: `region[i] += decryption_table[(i ^ 1) & 0xff]`. Combined, for even `src` / `dest` the
68000 sees `D[src ... ]` where `D[j] = file[j] + decryption_table[j & 0xff]` -- the plain decrypted file in order -- and the directory's
16-bit fields are read from the byte-swapped image (so in file order they are big-endian). `tools/toybox_model.py` implements exactly MAME's
indexing; the vectors prove it. (On a big-endian host MAME's cmd 02 / 42 / 03 results would differ; the games' behaviour under MAME on
x86 is what the project follows.)

## 4. What the games issue (from the captures)

| | jchan / jchana | jchan2 |
|---|---|---|
| boot, after the ~7 s watchdog-kicking delay (frame ~440) | 04/3d,3e,3f -> 0280 (the strings "USMM0713-TB1994 ", "1995/05/24 The kung-Fu Master Jackie Chan" (jchan2: "1995/10/24 Fists Of Fire") and "(C)1995 KANEKO // TEAM JACKIE CHAN"); 03 -> 0200; 02 x3 -> 0100; 42 <- 0100 | same |
| game start (frames ~1925) | 04 / 1b,1c,2d,12,13,24,25,00,02 -> 1000, 1800, 3800, 0600, 0700, 2000, 0300 | 04 / 2d,21,1f,18,16,2a,28,22,23,19,1a,2b,2c -> 0300, 0600, 0e00, 0400, 0500, 1800 |
| not used in play | no command during a fight (the data tables are loaded once) | |

The data the MCU delivers is only ever read from `0x10000 ...`; the used part is 0x10200-0x1556e (jchan) / 0x15388 (jchan2) -- **22 KB**
of the 128 KB ROM (49 / 31 non-empty directory entries, longest 864 / 1408 bytes). The first 64 KB of the ROM are never read by the model.

## 5. State an implementation needs

mailbox 4 x 16 bit; the 93C46 as 64 x 16 (the 68000 never talks to the chip: only cmds 02 / 42 do; erased = 0xffff at power-up when
`nvram` has no file); the DIP word (a plain input); a ROM of 22 KB (or the whole 128 KB) for cmd 04; a port into the shared RAM (read the
parameter words + write result bytes; byte writes with the `^ 1` mapping for cmd 04). The EEPROM contents should be saved like the other cores'
(MiSTer: the same `nvram` mechanism as other 93C46 cores).

## 6. Files (work/toybox/, regenerated by the tools; not in the repository)

| file | |
|---|---|
| `<set>.cmds.bin`, `<set>.log` | the raw capture of a real boot + game start (`tools/toybox_capture.py`): every mailbox / status access with the PC, and the 64 KB RAM before and after each command |
| `<set>.cases.txt`, `<set>.probe.txt` | generated cases sent to MAME (`tools/lua/toybox_probe.lua`) and the bytes that changed |
| `<set>.vectors.json` | everything above in one JSON (probe cases + game commands, expected changed bytes) |
| `<set>.vectors.txt` | the **bench input**: flat text, grammar in the file's header (CASE / DSW / SETUP / W16 / W8 / R16 / R8 / READ / EXPECT, and GAME / PRE / SRC / EE / EXPECT); ~0.55 MB |
| `<set>.mcudata.dec.bin` | the data ROM as the MCU works on it (128 KB, MAME region byte order, decrypted): the contents the RTL's ROM must hold (offsets 0x10000-0x15fff matter) |

Coverage of the 163 probe cases: all non-empty directory entries (every `sub`), `sub` with the high bits set (masking), odd and
end-of-RAM destinations, 7 DIP words, EEPROM round trips with 6 patterns (including odd destinations), the 10 ignored commands, 13
mailbox-protocol sequences (order, partial, byte-wide, repeated, status reads).

## 7. Regenerating

```
py -3.8 mister/tools/toybox_capture.py --fresh --play <set>     # real boot + game start (62 s of emulated time, ~20 s)
py -3.8 mister/tools/toybox_vectors.py <set>                    # generated cases through MAME, model check, writes the files above
py -3.8 mister/tools/toybox_flatcheck.py <set>                  # the flat file vs the model (the reference reader for a bench)
py -3.8 mister/tools/toybox_model.py <set>                      # the model vs the captured game commands only
```
