-- Log the inter-CPU / control writes of a jchan run with the frame number, in the format of the RTL bench's +TRACE ("frame cpu addr R/W be data"),
-- for tools/ipc_compare.py:  main 403ffe (command to the sub CPU), main f00000-f00007 (control: bit 15 = sub IRQ enable), sub 400000 (message to main),
-- main 330000-360000 (toybox mailbox), sub 800000-800003 is NOT logged here (tools/lua/ymz_log.lua).
--   JC_IPCLOG  output file
local m      = manager.machine
local mainsp = m.devices[":maincpu"].spaces["program"]
local subsp  = m.devices[":sub"].spaces["program"]
local scr    = m.screens[":screen"]
local out    = assert(io.open(os.getenv("JC_IPCLOG") or "ipclog.txt", "w"))

local function log(cpu, addr, data, mask)
  local be = 0
  if (mask & 0xff00) ~= 0 then be = be | 2 end
  if (mask & 0x00ff) ~= 0 then be = be | 1 end
  out:write(string.format("%d %s %06x W %d %04x\n", scr:frame_number(), cpu, addr, be, data & 0xffff))
end

TAP1 = mainsp:install_write_tap(0x403ffe, 0x403fff, "m_cmd", function(offset, data, mask) log("M", 0x403ffe, data, mask) end)
TAP2 = mainsp:install_write_tap(0xf00000, 0xf00007, "m_ctrl", function(offset, data, mask) log("M", 0xf00000 + (offset & 6), data, mask) end)
TAP3 = subsp:install_write_tap(0x400000, 0x400001, "s_msg", function(offset, data, mask) log("S", 0x400000, data, mask) end)
TAP4 = mainsp:install_write_tap(0x330000, 0x330001, "m_tbx0", function(offset, data, mask) log("M", 0x330000, data, mask) end)
TAP5 = mainsp:install_write_tap(0x340000, 0x340001, "m_tbx1", function(offset, data, mask) log("M", 0x340000, data, mask) end)
TAP6 = mainsp:install_write_tap(0x350000, 0x350001, "m_tbx2", function(offset, data, mask) log("M", 0x350000, data, mask) end)
TAP7 = mainsp:install_write_tap(0x360000, 0x360001, "m_tbx3", function(offset, data, mask) log("M", 0x360000, data, mask) end)
emu.register_frame_done(function() if scr:frame_number() % 60 == 0 then out:flush() end end)
