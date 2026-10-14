-- Which parts of the main CPU's 64 KB `mcuram` (300000-30ffff) does a play session touch?  Counts reads and writes per 1 KB block (taps on the whole
-- window) and rewrites <JC_OUT>.txt every 300 frames (MAME does not run the stop notifiers on -seconds_to_run); JC_INPUT = input script as in
-- dump.lua / toybox_log.lua (mamedump.play_script()).
local m   = manager.machine
local out = os.getenv("JC_OUT") or "mcuram_extent"
local scr = m.screens[":screen"]
local cpu = m.devices[":maincpu"]
local sp  = cpu.spaces["program"]

local events = {}
for ev in string.gmatch(os.getenv("JC_INPUT") or "", "[^;]+") do
  local fr, port, field, val = string.match(ev, "^(%d+):([^:]+):([^:]+):(%d+)$")
  if fr then
    fr = tonumber(fr)
    events[fr] = events[fr] or {}
    table.insert(events[fr], { port = ":" .. port, field = field, value = tonumber(val) })
  end
end

local MCURAM = 0x300000
local rd, wr = {}, {}
for i = 0, 63 do rd[i] = 0; wr[i] = 0 end
local first_hi = nil
local last_frame = 0

local function report()
  local f = io.open(out .. ".txt", "w")
  if not f then return end
  f:write("frames " .. tostring(last_frame) .. "\n")
  for b = 0, 63 do
    if rd[b] > 0 or wr[b] > 0 then
      f:write(string.format("%04x-%04x  reads %d  writes %d\n", b * 1024, b * 1024 + 1023, rd[b], wr[b]))
    end
  end
  f:write("first access at or above 0x4000: " .. tostring(first_hi) .. "\n")
  f:close()
end

-- keep the taps in a global (MAME drops a tap whose handler object is collected)
TAPS = {}
TAPS[#TAPS + 1] = sp:install_read_tap(MCURAM, MCURAM + 0xffff, "mc_r", function(offset, data, mask)
  local b = (offset - MCURAM) >> 10
  rd[b] = rd[b] + 1
  if b >= 16 and not first_hi then first_hi = string.format("read %06x frame %d", offset, last_frame) end
  return nil
end)
TAPS[#TAPS + 1] = sp:install_write_tap(MCURAM, MCURAM + 0xffff, "mc_w", function(offset, data, mask)
  local b = (offset - MCURAM) >> 10
  wr[b] = wr[b] + 1
  if b >= 16 and not first_hi then first_hi = string.format("write %06x frame %d", offset, last_frame) end
  return nil
end)

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
