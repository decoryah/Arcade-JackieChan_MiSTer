-- Which palette entries (700000-70ffff, main CPU) does a play session read and write after the boot RAM test?  Per 1 K-word block (32 blocks):
-- reads / writes counted from frame JC_FROM on; rewritten to <JC_OUT>.txt every 300 frames.  JC_INPUT as in wram_extent.lua.
local m   = manager.machine
local out = os.getenv("JC_OUT") or "palextent"
local from = tonumber(os.getenv("JC_FROM") or "100")
local scr = m.screens[":screen"]
local sp  = m.devices[":maincpu"].spaces["program"]
local BASE = 0x700000
local rd, wr = {}, {}
for i = 0, 31 do rd[i] = 0; wr[i] = 0 end
local frame = 0
local events = {}
for ev in string.gmatch(os.getenv("JC_INPUT") or "", "[^;]+") do
  local fr, port, field, val = string.match(ev, "^(%d+):([^:]+):([^:]+):(%d+)$")
  if fr then
    fr = tonumber(fr)
    events[fr] = events[fr] or {}
    table.insert(events[fr], { port = ":" .. port, field = field, value = tonumber(val) })
  end
end
local function report()
  local f = io.open(out .. ".txt", "w")
  f:write("frames " .. tostring(frame) .. " (counting from " .. tostring(from) .. ")" .. string.char(10))
  for b = 0, 31 do
    f:write(string.format("  %04x-%04x  reads %d  writes %d", b * 1024, b * 1024 + 1023, rd[b], wr[b]) .. string.char(10))
  end
  f:close()
end
TAPS = {}
TAPS[1] = sp:install_write_tap(BASE, BASE + 0xffff, "pal_w", function(offset, data, mask)
  if frame >= from then local b = (offset - BASE) >> 11; wr[b] = wr[b] + 1 end
  return nil
end)
TAPS[2] = sp:install_read_tap(BASE, BASE + 0xffff, "pal_r", function(offset, data, mask)
  if frame >= from then local b = (offset - BASE) >> 11; rd[b] = rd[b] + 1 end
  return nil
end)
emu.register_frame_done(function()
  frame = scr:frame_number()
  if frame % 300 == 0 then report() end
  local ev = events[frame]
  if ev then
    for _, e in ipairs(ev) do
      local p = m.ioport.ports[e.port]
      if p and p.fields[e.field] then p.fields[e.field]:set_value(e.value) end
    end
  end
end)
