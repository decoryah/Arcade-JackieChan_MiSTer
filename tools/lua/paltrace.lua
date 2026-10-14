-- Logs the main CPU's writes to a palette range (default the first 32 words) with frame number, scanline and PC.
--   JC_OUT   output file prefix        JC_PAL_LO / JC_PAL_HI  byte range (default 0x700000-0x70003f)
local m   = manager.machine
local out = os.getenv("JC_OUT") or "paltrace"
local lo  = tonumber(os.getenv("JC_PAL_LO") or "0x700000")
local hi  = tonumber(os.getenv("JC_PAL_HI") or "0x70003f")
local cpu = m.devices[":maincpu"]
local sp  = cpu.spaces["program"]
local scr = m.screens[":screen"]
local f = io.open(out .. ".txt", "w")
local n = 0
local PERIOD = 460 * 261 * 4 / 28636363.0
TAPS = {}
TAPS[#TAPS + 1] = sp:install_write_tap(lo, hi, "pal_w", function(offset, data, mask)
  n = n + 1
  local ok, err = pcall(function()
    local pc = cpu.state["PC"].value
    f:write(string.format("F%d v%d W %06x %04x m%04x pc %06x\n", scr:frame_number(), math.floor(((m.time:as_double() % PERIOD) / PERIOD) * 261), offset, data, mask, pc))
  end)
  if not ok then f:write("# err " .. tostring(err) .. "\n") end
  return nil
end)
emu.register_frame_done(function()
  if scr:frame_number() % 10 == 0 then f:write(string.format("# frame %d taps %d\n", scr:frame_number(), n)) end
  f:flush()
end)
