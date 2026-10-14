# Sound: the YMZ280B (`rtl/jchan_ymz280b.sv`)

The board's only sound hardware is one Yamaha YMZ280B (8 voices of 4-bit ADPCM / 8-bit PCM / 16-bit PCM, 16 MHz, stereo) driven by the **sub 68000**
(`800000-800003`, low byte: `800001` register select, `800003` data; write only) and fed from 3.25 MB of sample ROM. There is no separate sound CPU
(the sound driver is part of the sub CPU's program), no read access to the chip and no interrupt wiring in MAME's driver.

## 1. Reference

`devices/sound/ymz280b.cpp` of MAME 0.289 (pinned in `ref/mame/src/devices/sound/`), exactly as the other chips: MAME is the oracle.

* `tools/ymz_ref.py` **generates a C++ harness from that file**: the voice struct, the three decoders, `write_to_register`, the level / pan maths and
  `sound_stream_update` are cut out of the source text verbatim (nothing re-typed) and wrapped in a few stubs. It replays what MAME's sound system does
  around the chip: a data-port write first updates the stream up to and including the sample index of its time (`idx - written + 1` samples),
  then writes; every 1/50 s the sound manager updates every stream; the stream rate is the integer 83333 Hz.
  Output: per output sample the left / right sums of the voices' `interp * level / 2` integers (the numbers MAME hands to
  `stream.add_int(..., 32768 * 256)`), i.e. the 16-bit sample is `sum / 256`.
* `tools/ymz_capture.py` + `tools/lua/ymz_log.lua` log the sub CPU's writes to `800000-800003` with MAME's machine time during a real run (boot +
  attract + a played game, 70 s, 517,682 register writes, ADPCM with and without loops and PCM8; nothing uses PCM16, panning is always centre),
  and MAME's own `-wavwrite` output of the same run.
* **Does the harness reproduce MAME's real output?** `tools/xcheck/wavcmp.cpp` resamples the harness's 83.33 kHz stream to MAME's 48 kHz (windowed
  sinc), finds the lag (-3 samples and a fraction) and compares: **level ratio 1.0024, SNR 37 dB** over 70 s (all blocks 35-39 dB). The residual is
  the difference between two band-limiting resamplers (MAME's HQ resampler is not reproducible bit for bit; the SNR hardly changes when both are
  low-passed at 4 kHz), the stream positions of the writes are quantised to the nanosecond of the log. Moving the 1/50 s update by 7 ms or removing it
  does not change the SNR: with a register burst every frame, the writes dominate the chunk boundaries.

## 2. The RTL

One sample every 1152 clocks (96 MHz / 83.333 kHz; `TICK_CLKS`), the 8 voices processed one after the other in the following ~100-600 clocks. A
time-multiplexed single decoder: 3 multipliers, 8 x ~300 bits of voice state, a 64 x 16 write queue, ~4 ROM byte reads per voice per sample at most
(the game needs far fewer).

* **Registers**: voice registers `00-7f` (pitch, key-on / loop / mode, total level, pan, start / loop start / loop end / stop addresses as three
  bytes each) and `ff` (key-on enable, with its "stop everything" / "restart looping voices" side effects); `80-87`, `fe` (DSP, external memory,
  IRQ mask) are accepted and ignored. The CPU's writes go into the queue; the address-register write is immediate.
* **Decoders**: ADPCM (`step * diff / 8` truncating toward zero, clamp, the 8-entry `index_scale`, step clamp `0x7f..0x6000`, loop restore of
  signal / step at the first pass of loop start), PCM8 (`s8 * 256`), PCM16 (little endian), loop / stop handling as MAME's three `generate_*`.
* **Output**: per voice linear interpolation between the last two decoded samples with a 9-bit fraction (`(prev * (512 - pos) + curr * pos) >> 9`),
  times the left / right volume `/ 2`, summed; `out_l / out_r` = `(sum + 128) >> 8` saturated to 16 bit; `dbg_l / dbg_r` the raw 28-bit sums.
* **Pitch**: `output_step = (fnum & 0xff (ADPCM) | 0x1ff) + 1`, position advanced by it every output sample, a new input sample when the 9-bit
  fraction wraps: input rate `(fnum + 1) / 256 * 41.667 kHz` as the datasheet says.

### 2.1 Mapping MAME's chunked stream onto a sample machine

MAME generates samples in *chunks* (it only updates the stream at a data write and every 1/50 s) and several of its behaviours depend on the chunk:
a write at stream index N takes effect from sample N+1; at the start of a chunk an idle voice (not playing, last two samples 0) is parked at
`output_pos = 1.0` and skipped; the "ramp to zero" `t = t * 15 / 16` that fills the *rest of the chunk* after a sample ended stops at the chunk
boundary and a stopped voice then decodes zeros; the interpolation position is advanced eagerly after an output that wrapped it, so a chunk always
ends with `output_pos < 1.0`. The RTL reproduces all of that sample by sample and causally: writes wait in the queue and are applied between two ticks,
every data write and every 1/50 s event flags the next sample as a chunk start (quick-out test, ramp cut), the position advance is eager.
The equality with MAME's batch code is what the bench below checks, not an assumption.

## 3. Verification: RTL == MAME's chip code, sample by sample (`sim/run_ymz.sh`, `tools/ymz_prep.py`, `tools/ymz_random.py`, `sim/tb_jchan_ymz.cpp`)

The bench feeds an event list (writes placed in the sample period MAME's stream index gives them; the RTL makes its own 1/50 s events), serves the ROM
with a configurable latency (+ random 0..3 clocks), and compares **both channels' 28-bit sums of every output sample** with the harness.

| run | samples | events | result |
|---|---|---|---|
| captured session, first 30 s (boot register clears, first ADPCM key-ons with loops), 400 clocks / sample, ROM latency 3 + random | 2.50 M | 442 K | **0 mismatching** |
| captured session, whole 70 s (boot, attract, a played game: PCM8, loops, up to 8 voices), 400 clocks / sample, ROM latency 3 + random | 5.83 M | 1.04 M | **0 mismatching** |
| captured session, first 25 s at the real 1152 clocks / sample, ROM latency 2 + random | 2.08 M | 295 K | **0 mismatching** |
| **random register stress**, 30 seeds x 30,000 samples, 400 clocks / sample, ROM latency 2 + random: all three formats incl. PCM16, loops with / without key-off, retriggers in mid-play, every pan value, full pitch range, sample ends, the global key-on enable, ignored registers | 0.9 M | 95 K | **0 mismatching** |
| random stress, 4 seeds x 20,000 samples at the real 1152 clocks / sample, ROM latency 12 + random (timing budget; no overrun) | 80 K | | **0 mismatching** |

Bugs the benches found (all in my RTL, none in the model): a 15 x 10 bit multiply in a 17-bit context (the ADPCM step update overflowed); the 1/50 s
event counted one sample too early (it belongs to the period that starts at the tick that generated it); the pan / level divide-by-7 intermediate one
bit too narrow (pan != 8 only: the game never uses it, the random test did); the first chunk after reset not parking idle voices (writes before the
first event); the ADPCM sum one bit too narrow at full-scale saturation (-32768 - 46080).

## 4. In the core

`jchan_core` connects the board's `ymz_*` write port to the chip and exposes `ymz_rom_*` (24-bit byte address, request held until a one-clock ack) and
`audio_*` (`audio_valid` one clock per sample, `audio_l / r` 16 bit, `audio_sum_l / r` the exact sums). The bench top models the 16 MB region; the
memory controller must return what MAME's region holds: `jc-301` at 0 and again at `0x100000`, `jc-300` at `0x200000`, the 256 KB EPROM at `0x400000`,
zeros above `0x440000` (`tools/jchan_rom.py` builds the region the same way: `work/rom/<set>.ymz.bin`).

* **Output rate**: the chip block makes 83.33 kHz (MAME's internal stream rate; the chip itself outputs at 16 MHz / 384 = 41.67 kHz and MAME
  interpolates every voice at twice that). `rtl/jchan_audio48.sv` brings it to the 48 kHz of the MiSTer audio output by averaging the held stream over
  each 2000-clock period (a box filter, `jchan_core` outputs `audio48_*`); the bench `sim/run_audio48.sh` checks it against its definition
  (0 differences) and against the exact average (within 1 LSB). Whether a steeper filter is wanted is a listening question for the hardware.
* **Whole-core audio check**: `sim/run_core.sh ... +YMZROM=.. +AUDIO=<file>` writes the core's sums; compared with MAME's wav of the same time with
  `wavcmp` (see the result in section 5).

## 5. Not done

* The chip's status register / IRQ output and the ROM read-back are not implemented (nothing on this board can reach them).
* PCM16 has not been exercised by this game (the harness comparison covers it only through the generic decode path): no capture uses it.
* The 48 kHz output stage, the SDRAM sample-ROM client and a volume control belong to the MiSTer top.
