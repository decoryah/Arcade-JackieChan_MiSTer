-- Dump jchan's CPU-visible memories at chosen frames, from reset, for the CPU-side system bench (tools/sys_compare.py, sim/run_sys.sh).
--
--   JC_OUT      output prefix (directory must exist), e.g. dumps/sys_jchan
--   JC_FRAMES   comma list of frame numbers to dump, e.g. "10,100,500"
--   JC_INPUT    optional input script, ';'-separated "frame:port:field:value" (value 1 = pressed), as dump.lua
--   JC_SNAP     1 = also write MAME's snapshot of each dumped frame (snap/<basename of JC_OUT>.fNNNNN.png)
--
-- Per dumped frame N: <JC_OUT>.fNNNNN.<region>.bin, regions (68000 byte order, as the RTL bench's dump task writes them):
--   mwram   main work RAM 200000-20ffff        swram   sub work RAM 100000-10ffff
--   mcu     mcuram 300000-30ffff               shared  shared RAM 400000-403fff
--   spr1    main 500000-503fff                 spr2    sub 700000-703fff        (live lists)
--   spr1p   spr1 as it was at the end of frame N-1 (the list MAME's draw of frame N uses, jchan.cpp `vblank`)    spr2p likewise
--   sreg1   main 600000-60003f                 sreg2   sub 780000-78003f
--   v2regs  sub 600000-60001f                  v2vram  sub 500000-503fff       pal  main 700000-70ffff
-- plus <JC_OUT>.ports.txt with the four input port words (P1 P2 SYSTEM EXTRA) and DSW1 as MAME reads them at the first dump.
-- Reads go through the program space with side effects disabled (they are plain RAM, nothing here has a read side effect).
local m      = manager.machine
local out    = os.getenv("JC_OUT") or "sysdump"
local scr    = m.screens[":screen"]
local mainsp = m.devices[":maincpu"].spaces["program"]
local subsp  = m.devices[":sub"].spaces["program"]

local want = {}
for f in string.gmatch(os.getenv("JC_FRAMES") or "10", "%d+") do want[tonumber(f)] = true end

local events = {}
for ev in string.gmatch(os.getenv("JC_INPUT") or "", "[^;]+") do
  local fr, port, field, val = string.match(ev, "^(%d+):([^:]+):([^:]+):(%d+)$")
  if fr then
    fr = tonumber(fr)
    events[fr] = events[fr] or {}
    table.insert(events[fr], { port = ":" .. port, field = field, value = tonumber(val) })
  end
end

local function wr(path, str)
  local f = assert(io.open(path, "wb"))
  f:write(str)
  f:close()
end

local function pbytes(space, base, n)
  return space:read_range(base, base + n - 1, 8)
end

local prev1 = string.rep("\0", 0x4000)
local prev2 = string.rep("\0", 0x4000)
local ports_done = false

emu.register_frame_done(function()
  local n = scr:frame_number()

  local ev = events[n]
  if ev then
    for _, e in ipairs(ev) do
      local p = m.ioport.ports[e.port]
      if p and p.fields[e.field] then p.fields[e.field]:set_value(e.value)
      else print("input event: no such field " .. e.port .. " / " .. e.field) end
    end
  end

  local cur1 = pbytes(mainsp, 0x500000, 0x4000)
  local cur2 = pbytes(subsp, 0x700000, 0x4000)
  if want[n] then
    if not ports_done then
      local t = {}
      for _, name in ipairs({ ":P1", ":P2", ":SYSTEM", ":EXTRA", ":DSW1" }) do
        local p = m.ioport.ports[name]
        t[#t + 1] = string.format("%s %04x", name:sub(2), p and (p:read() & 0xffff) or 0xffff)
      end
      wr(out .. ".ports.txt", table.concat(t, "\n") .. "\n")
      ports_done = true
    end
    local p = string.format("%s.f%05d", out, n)
    wr(p .. ".mwram.bin", pbytes(mainsp, 0x200000, 0x10000))
    wr(p .. ".swram.bin", pbytes(subsp, 0x100000, 0x10000))
    wr(p .. ".mcu.bin", pbytes(mainsp, 0x300000, 0x10000))
    wr(p .. ".shared.bin", pbytes(mainsp, 0x400000, 0x4000))
    wr(p .. ".spr1.bin", cur1)
    wr(p .. ".spr2.bin", cur2)
    wr(p .. ".spr1p.bin", prev1)
    wr(p .. ".spr2p.bin", prev2)
    wr(p .. ".sreg1.bin", pbytes(mainsp, 0x600000, 0x40))
    wr(p .. ".sreg2.bin", pbytes(subsp, 0x780000, 0x40))
    wr(p .. ".v2regs.bin", pbytes(subsp, 0x600000, 0x20))
    wr(p .. ".v2vram.bin", pbytes(subsp, 0x500000, 0x4000))
    wr(p .. ".pal.bin", pbytes(mainsp, 0x700000, 0x10000))
    if os.getenv("JC_SNAP") == "1" then
      scr:snapshot(string.format("%s.f%05d.png", out:match("([^/\\]+)$"), n))   -- the picture of frame N, in MAME's snapshot directory
    end
    print(string.format("dumped frame %d", n))
  end
  prev1, prev2 = cur1, cur2
end)
