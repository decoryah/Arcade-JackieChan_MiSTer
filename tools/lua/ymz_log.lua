-- Log the sub CPU's writes to the YMZ280B (jchan: 800000-800003, low byte), with the machine time, for the sound model / RTL benches.
--   JC_YMLOG  output file: one line per write  "<seconds as %.9f> <offset 0|1> <data hex> <frame>"
--             offset 0 = register select (800001), 1 = data (800003)
--   JC_INPUT  optional input script, "frame:port:field:value;..." as dump.lua (value 1 = pressed)
local m      = manager.machine
local subsp  = m.devices[":sub"].spaces["program"]
local scr    = m.screens[":screen"]
local out    = assert(io.open(os.getenv("JC_YMLOG") or "ymlog.txt", "w"))

local function now()
  local ok, t = pcall(function() return m.time:as_double() end)
  if ok and t then return t end
  return emu.time():as_double()
end

YMTAP = subsp:install_write_tap(0x800000, 0x800003, "ymlog", function(offset, data, mask)
  -- offset is the byte address relative to the tap start for 16-bit access: 0 / 2; the low byte carries the value
  if (mask & 0x00ff) ~= 0 then
    out:write(string.format("%.9f %d %02x %d\n", now(), (offset >> 1) & 1, data & 0xff, scr:frame_number()))
  end
end)

local events = {}
for ev in string.gmatch(os.getenv("JC_INPUT") or "", "[^;]+") do
  local fr, port, field, val = string.match(ev, "^(%d+):([^:]+):([^:]+):(%d+)$")
  if fr then
    fr = tonumber(fr)
    events[fr] = events[fr] or {}
    table.insert(events[fr], { port = ":" .. port, field = field, value = tonumber(val) })
  end
end
emu.register_frame_done(function()
  local n = scr:frame_number()
  local ev = events[n]
  if ev then
    for _, e in ipairs(ev) do
      local p = m.ioport.ports[e.port]
      if p and p.fields[e.field] then p.fields[e.field]:set_value(e.value) end
    end
  end
  if n % 60 == 0 then out:flush() end
end)
