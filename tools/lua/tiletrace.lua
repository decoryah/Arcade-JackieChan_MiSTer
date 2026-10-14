-- Logs the sub CPU's writes to the VIEW2 tile RAM (500000-503fff) and the palette writes of the main CPU: frame, scanline (from the machine time), address.
--   JC_OUT   output file prefix
local m   = manager.machine
local out = os.getenv("JC_OUT") or "tiletrace"
local sub = m.devices[":sub"]
local main = m.devices[":maincpu"]
local scr = m.screens[":screen"]
local f = io.open(out .. ".txt", "w")
local PERIOD = 460 * 261 * 4 / 28636363.0
TAPS = {}
local function line() return math.floor(((m.time:as_double() % PERIOD) / PERIOD) * 261) end
TAPS[#TAPS + 1] = sub.spaces["program"]:install_write_tap(0x500000, 0x503fff, "t_w", function(offset, data, mask)
  f:write(string.format("F%d v%d T %06x %04x\n", scr:frame_number(), line(), offset, data))
  return nil
end)
TAPS[#TAPS + 1] = main.spaces["program"]:install_write_tap(0x700000, 0x70ffff, "p_w", function(offset, data, mask)
  f:write(string.format("F%d v%d P %06x %04x\n", scr:frame_number(), line(), offset, data))
  return nil
end)
emu.register_frame_done(function() f:flush() end)
