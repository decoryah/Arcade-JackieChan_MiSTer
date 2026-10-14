-- What does the boot RAM test do to the palette RAM (700000-70ffff, main CPU)?  Logs the first events and a value histogram for the first
-- <JC_FRAMES> frames: writes (addr, data) and reads (addr, data, expected = last written value of that word).
local m   = manager.machine
local out = os.getenv("JC_OUT") or "paltest"
local nfr = tonumber(os.getenv("JC_FRAMES") or "40")
local scr = m.screens[":screen"]
local sp  = m.devices[":maincpu"].spaces["program"]
local BASE = 0x700000
local mem = {}
local wr_n, rd_n, rd_bad = 0, 0, 0
local vals = {}
local log = {}
local frame = 0
local function L(s) if #log < 400 then log[#log + 1] = s end end
TAPS = {}
TAPS[1] = sp:install_write_tap(BASE, BASE + 0xffff, "pal_w", function(offset, data, mask)
  local a = (offset - BASE) >> 1
  wr_n = wr_n + 1
  local k = string.format("%04x", data & 0xffff)
  vals[k] = (vals[k] or 0) + 1
  L(string.format("f%d W %04x <- %04x mask %04x", frame, a, data & 0xffff, mask & 0xffff))
  if mask == 0xffff then mem[a] = data & 0xffff else mem[a] = nil end
  return nil
end)
TAPS[2] = sp:install_read_tap(BASE, BASE + 0xffff, "pal_r", function(offset, data, mask)
  local a = (offset - BASE) >> 1
  rd_n = rd_n + 1
  local e = mem[a]
  if e ~= nil and e ~= (data & 0xffff) then rd_bad = rd_bad + 1 end
  L(string.format("f%d R %04x -> %04x (last written %s)", frame, a, data & 0xffff, e and string.format("%04x", e) or "-"))
  return nil
end)
emu.register_frame_done(function()
  frame = scr:frame_number()
  if frame == nfr then
    local f = io.open(out .. ".txt", "w")
    f:write(string.format("frames %d: %d writes, %d reads, %d reads differing from the last full-word write", frame, wr_n, rd_n, rd_bad) .. string.char(10))
    local ks = {}
    for k, v in pairs(vals) do ks[#ks + 1] = k end
    table.sort(ks)
    for _, k in ipairs(ks) do f:write(string.format("  value %s written %d times", k, vals[k]) .. string.char(10)) end
    for _, s in ipairs(log) do f:write(s .. string.char(10)) end
    f:close()
  end
end)
