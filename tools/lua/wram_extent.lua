-- Which parts of the two 68000s' 64 KB work RAMs (main 200000-20ffff, sub 100000-10ffff) does a play session touch?  Counts reads and writes per
-- 1 KB block (taps on the whole windows, both CPUs' address spaces) and rewrites <JC_OUT>.txt every 300 frames (MAME does not run the stop
-- notifiers on -seconds_to_run); JC_INPUT = input script as in dump.lua / toybox_log.lua (mamedump.play_script()).
local m   = manager.machine
local out = os.getenv("JC_OUT") or "wram_extent"
local scr = m.screens[":screen"]

local events = {}
for ev in string.gmatch(os.getenv("JC_INPUT") or "", "[^;]+") do
  local fr, port, field, val = string.match(ev, "^(%d+):([^:]+):([^:]+):(%d+)$")
  if fr then
    fr = tonumber(fr)
    events[fr] = events[fr] or {}
    table.insert(events[fr], { port = ":" .. port, field = field, value = tonumber(val) })
  end
end

local last_frame = 0
local areas = {
  { name = "main", tag = ":maincpu", base = 0x200000 },
  { name = "sub",  tag = ":sub",     base = 0x100000 },
}
for _, a in ipairs(areas) do
  a.rd, a.wr = {}, {}
  for i = 0, 63 do a.rd[i] = 0; a.wr[i] = 0 end
end

local function report()
  local f = io.open(out .. ".txt", "w")
  if not f then return end
  f:write("frames " .. tostring(last_frame) .. string.char(10))
  for _, a in ipairs(areas) do
    f:write(a.name .. string.char(10))
    for b = 0, 63 do
      if a.rd[b] > 0 or a.wr[b] > 0 then
        f:write(string.format("  %04x-%04x  reads %d  writes %d", b * 1024, b * 1024 + 1023, a.rd[b], a.wr[b]) .. string.char(10))
      end
    end
  end
  f:close()
end

-- keep the taps in a global (MAME drops a tap whose handler object is collected)
TAPS = {}
for _, a in ipairs(areas) do
  local sp = m.devices[a.tag].spaces["program"]
  local base, rd, wr = a.base, a.rd, a.wr
  TAPS[#TAPS + 1] = sp:install_read_tap(base, base + 0xffff, a.name .. "_r", function(offset, data, mask)
    local b = (offset - base) >> 10
    rd[b] = rd[b] + 1
    return nil
  end)
  TAPS[#TAPS + 1] = sp:install_write_tap(base, base + 0xffff, a.name .. "_w", function(offset, data, mask)
    local b = (offset - base) >> 10
    wr[b] = wr[b] + 1
    return nil
  end)
end

emu.register_frame_done(function()
  local n = scr:frame_number()
  last_frame = n
  if n % 300 == 0 then report() end
  local ev = events[n]
  if ev then
    for _, e in ipairs(ev) do
      local p = m.ioport.ports[e.port]
      if p and p.fields[e.field] then p.fields[e.field]:set_value(e.value)
      else print("input event: no such field " .. e.port .. " / " .. e.field) end
    end
  end
end)
