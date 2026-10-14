# MAME 0.289 Lua: things that cost time (jchan work)

Each of these produced silently wrong or empty output at first.

* **A tap dies when its handler object is garbage collected.** `sp:install_write_tap(...)` / `install_read_tap(...)` return a handler object;
  if nothing refers to it, MAME removes the tap at the next Lua GC. A chunk-level `local taps = {}` that no callback uses is collected as soon
  as the script has loaded -- keep the handlers in a *global* (`TAPS = {}`). Symptom: the tap sees the first frame's accesses, then nothing
  (this is what METHODOLOGY.md's "a tap may not see accesses that go through an installed write handler" probably was). Lua-originated bus
  accesses (`sp:write_u16`) keep seeing the tap longer than CPU accesses do, which makes it look as if CPU accesses bypass taps.
* **Errors inside tap callbacks are swallowed** -- the tap just does nothing. `scr:vpos()` does not exist in this build (`attempt to call a
  nil value`): wrap callback bodies in `pcall` and print while developing.
* **`emu.register_stop` does not exist**; use `emu.add_machine_stop_notifier(function() ... end)`. Open log files with `flush()` after each
  write if the stop notifier may not run.
* **Reads made from inside a tap go through the taps again**: a snapshot taken in a read tap must clear its "pending" flag *first*, or it recurses.
* **DIP switches**: setting `field.user_value` inside a frame callback takes effect on the next frame (the port updates its defaults per frame).
  A script that changes DIPs and reads the port in the same callback sees the old value. `port:read()` returns the value the machine sees.
* `manager.machine:exit()` ends the run from a callback; `manager.machine.time:as_double()` prints with a decimal comma under this locale
  (`string.format("%.6f", x):gsub(",", ".")`).
* Tap callbacks: `function(offset, data, mask)`; for write taps `data` is the value being written and the return value replaces it
  (`return data | 0x1010` in dump.lua's `JC_NOTILES`; **not verified to be applied** -- the tile-layer disable in dump.lua was not needed in the end,
  the tile renderer in `jchan_tiles.py` made full-frame comparisons possible).
* Dumping memory from Lua: `space:read_u16()` per word is fast enough for 64 KB per command (~2 ms); do not use per-byte string building for
  megabytes (use the Python ROM builder for ROM regions).
