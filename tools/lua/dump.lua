-- Dump jchan machine state + MAME's own frame, for the reference renderer (tools/jchan_frame.py) and the RTL benches.
--
--   JC_OUT      output prefix (directory must exist), e.g. ../dumps/jchan
--   JC_FRAMES   comma list of frame numbers to dump, e.g. "100,300,800"
--   JC_INPUT    input script, ';'-separated "frame:port:field:value", value 1 = pressed,
--               e.g. "600:SYSTEM:Coin 1:1;605:SYSTEM:Coin 1:0"
--   JC_NOTILES  1 = force both VIEW2 layers off (a write tap on the VIEW2 layer-control register ORs in the two disable bits and the
--               register is also rewritten every frame), so MAME's snapshot shows only the two sprite layers over the 0x7f00 fill:
--               the sprite engines can then be compared on their own.
--
-- Per dumped frame N it writes <JC_OUT>.fNNNNN.{spr1,spr2,spr1p,spr2p,sreg1,sreg2,v2regs,v2vram,v2scr,pal}.bin and
-- the snapshot <name>.fNNNNN.png in MAME's snapshot directory.
--   spr1 / spr2    the two sprite lists (main CPU 500000-503fff, sub CPU 700000-703fff) as they are at the end of frame N
--   spr1p / spr2p  the same, as they were at the end of frame N-1.  MAME copies the sprite RAM into the chip's 32-bit buffer at scanline 240
--                  (jchan.cpp vblank), which can be before or after the frame's draw, so frame N is drawn from one of the two:
--                  tools/jchan_frame.py tries both and says which matches.
--   sreg1 / sreg2  the sprite register blocks (main 600000-60003f, sub 780000-78003f); live registers, no latch
--   v2regs         VIEW2 registers (sub 600000-60001f); v2vram VIEW2 tile RAM (sub 500000-503fff: vram_1, vram_0, scroll_1, scroll_0)
--   pal            palette RAM (main 700000-70ffff), 32768 xGRB555 words
local m      = manager.machine
local out    = os.getenv("JC_OUT") or "dump"
local scr    = m.screens[":screen"]
local mainsp = m.devices[":maincpu"].spaces["program"]
local subsp  = m.devices[":sub"].spaces["program"]

local want = {}
for f in string.gmatch(os.getenv("JC_FRAMES") or "60", "%d+") do want[tonumber(f)] = true end

local events = {}   -- frame -> list of {port, field, value}
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
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = string.char(space:read_u8(base + i)) end
  return table.concat(t)
end

local V2CTRL = 0x600008
if os.getenv("JC_NOTILES") == "1" then
  -- bit 12 = BG disable, bit 4 = FG disable (kaneko_tmap.cpp prepare_common)
  -- keep the handler object referenced: MAME removes a tap when it is garbage collected
  KEEP_TAP = subsp:install_write_tap(V2CTRL, V2CTRL + 1, "v2dis", function(offset, data, mask) return data | 0x1010 end)
end

local prev1 = string.rep("\0", 0x4000)
local prev2 = string.rep("\0", 0x4000)

emu.register_frame_done(function()
  local n = scr:frame_number()
  if os.getenv("JC_NOTILES") == "1" then
    subsp:write_u16(V2CTRL, subsp:read_u16(V2CTRL) | 0x1010)
  end

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
    local p = string.format("%s.f%05d", out, n)
    wr(p .. ".spr1.bin", cur1)
    wr(p .. ".spr2.bin", cur2)
    wr(p .. ".spr1p.bin", prev1)
    wr(p .. ".spr2p.bin", prev2)
    wr(p .. ".sreg1.bin", pbytes(mainsp, 0x600000, 0x40))
    wr(p .. ".sreg2.bin", pbytes(subsp, 0x780000, 0x40))
    wr(p .. ".v2regs.bin", pbytes(subsp, 0x600000, 0x20))
    wr(p .. ".v2vram.bin", pbytes(subsp, 0x500000, 0x4000))
    wr(p .. ".pal.bin", pbytes(mainsp, 0x700000, 0x10000))
    scr:snapshot(string.format("%s.f%05d.png", out:match("([^/\\]+)$"), n))
    print(string.format("dumped frame %d", n))
  end
  prev1, prev2 = cur1, cur2
end)
