-- Reads jchan's four input port words for a list of button combinations, for the RTL check of rtl/jchan_io.sv (tools/bench_io.py).
--   JC_COMBOS  ';'-separated "<dsw15>:<mask>" : dsw15 = 0 / 1 (Buttons Layout bit), mask = hex of the pressed set,
--              bit 0-7 joy1 {up down left right b1 b2 b3 b4}, 8-15 joy2, 16 start1, 17 start2, 18 coin1, 19 coin2, 20 test, 21 service, 22 tilt
--   JC_OUT     result file
local m = manager.machine
local scr = m.screens[":screen"]
local ports = m.ioport.ports
local combos = {}
for c in string.gmatch(os.getenv("JC_COMBOS") or "", "[^;]+") do
  local d, mk = string.match(c, "^(%d):(%x+)$")
  table.insert(combos, { d = tonumber(d), m = tonumber(mk, 16) })
end
local out = os.getenv("JC_OUT") or "io_probe.txt"

local function field(portname, fname)
  local p = ports[portname]
  if not p then return nil end
  return p.fields[fname]
end
local function setf(portname, fname, v)
  local f = field(portname, fname)
  if f then f:set_value(v) end
end

local names1 = { "Up", "Down", "Left", "Right", "Button 1", "Button 2", "Button 3", "Button 4" }
local idx = 0
local results = {}
local phase = 0
emu.register_frame_done(function()
  local n = scr:frame_number()
  if n < 5 then return end
  -- phase 0: apply combo idx+1; phase 1: read it (the inputs take effect on the next frame)
  if phase == 0 then
    idx = idx + 1
    local c = combos[idx]
    if not c then
      local f = assert(io.open(out, "w"))
      for _, r in ipairs(results) do f:write(r .. "\n") end
      f:close()
      manager.machine:exit()
      return
    end
    -- a DIP field's set_value toggles it from its default (3+1, bit 15 = 1): any non-zero value gives 2+2 (bit 15 = 0); the change shows a
    -- frame (or two, when going back) later, which the all-idle first combination of each group absorbs
    setf(":DSW1", "Buttons Layout", c.d == 1 and 0 or 0x8000)
    for pl = 1, 2 do
      for b = 0, 7 do
        local bit = (pl - 1) * 8 + b
        local v = ((c.m >> bit) & 1)
        local nm = "P" .. pl .. " " .. names1[b + 1]
        setf(":P" .. pl, nm, v)
        setf(":EXTRA", nm, v)
      end
    end
    setf(":SYSTEM", "1 Player Start", (c.m >> 16) & 1)
    setf(":SYSTEM", "2 Players Start", (c.m >> 17) & 1)
    setf(":SYSTEM", "Coin 1", (c.m >> 18) & 1)
    setf(":SYSTEM", "Coin 2", (c.m >> 19) & 1)
    setf(":SYSTEM", "Test", (c.m >> 20) & 1)
    setf(":SYSTEM", "Service 1", (c.m >> 21) & 1)
    setf(":SYSTEM", "Tilt", (c.m >> 22) & 1)
    phase = 1
  elseif phase == 1 then
    local r = {}
    for _, nm in ipairs({ ":P1", ":P2", ":SYSTEM", ":EXTRA", ":DSW1" }) do
      r[#r + 1] = string.format("%04x", ports[nm]:read() & 0xffff)
    end
    local c = combos[idx]
    results[#results + 1] = string.format("%d:%x %s", c.d, c.m, table.concat(r, " "))
    phase = 0
  end
end)
