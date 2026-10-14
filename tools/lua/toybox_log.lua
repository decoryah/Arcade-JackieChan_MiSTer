-- Log every access to the Kaneko "toybox" MCU mailbox of jchan (main CPU 330000 / 340000 / 350000 / 360000 writes, 370000 status reads),
-- and snapshot the MCU's shared RAM (main 300000-30ffff) around each executed command, for the RTL test vectors (tools/toybox_vectors.py).
--
--   JC_OUT      output prefix, e.g. ../toybox/jchan   (writes <JC_OUT>.log and <JC_OUT>.cmds.bin)
--   JC_INPUT    input script as in dump.lua ("frame:port:field:value;...")
--
-- <JC_OUT>.log is text, one access per line:
--     frame 0 time_s pc  W|R reg  data mask   (the second column is unused: this MAME has no screen:vpos())
-- <JC_OUT>.cmds.bin: for each command execution (the 4th mailbox word becoming 0xffff), in order:
--     u32 index, u32 frame, u32 pc, then 64 KB mcuram at the moment the command is triggered (before the MCU acts),
--     then 64 KB mcuram taken at the first main-CPU access to the mailbox / status / mcuram after the command (after the MCU acted).
-- (big-endian 68000 byte order, i.e. byte i is the byte at address 300000 + i).
local m      = manager.machine
local out    = os.getenv("JC_OUT") or "toybox"
local scr    = m.screens[":screen"]
local cpu    = m.devices[":maincpu"]
local sp     = cpu.spaces["program"]

local events = {}
for ev in string.gmatch(os.getenv("JC_INPUT") or "", "[^;]+") do
  local fr, port, field, val = string.match(ev, "^(%d+):([^:]+):([^:]+):(%d+)$")
  if fr then
    fr = tonumber(fr)
    events[fr] = events[fr] or {}
    table.insert(events[fr], { port = ":" .. port, field = field, value = tonumber(val) })
  end
end

local logf  = assert(io.open(out .. ".log", "w"))
local binf  = assert(io.open(out .. ".cmds.bin", "wb"))

local MCURAM = 0x300000
local function snap()
  local t = {}
  for i = 0, 0xffff, 2 do
    local w = sp:read_u16(MCURAM + i)
    t[#t + 1] = string.char((w >> 8) & 0xff, w & 0xff)
  end
  return table.concat(t)
end

-- NOTE: MAME removes a tap when the handler object returned by install_*_tap is garbage collected, and a chunk-level `local` table that no
-- closure refers to is collected once the script has loaded: keep the handlers in a GLOBAL.
TAPS = {}
local taps = TAPS
local com = { 0, 0, 0, 0 }
local ncmd = 0
local pending_post = false

local function pc() return cpu.state["PC"].value end

local function log(kind, reg, data, mask)
  logf:write(string.format("%d %d %s %06x %s %s %04x %04x\n", scr:frame_number(), 0, string.format("%.6f", m.time:as_double()):gsub(",", "."), pc(), kind, reg, data, mask))
end

local function post_check()
  if pending_post then
    pending_post = false          -- first: the snapshot's own reads go through the taps again
    binf:write(snap())
  end
end

local function u32(v) return string.char(v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff) end

local function mbox_write(n)
  return function(offset, data, mask)
    post_check()
    log("W", tostring(n), data, mask)
    -- MAME: COMBINE_DATA into the mailbox word (mask is 0xffff for the 68000's word writes)
    com[n + 1] = (com[n + 1] & ~mask) | (data & mask)
    if com[1] == 0xffff and com[2] == 0xffff and com[3] == 0xffff and com[4] == 0xffff then
      binf:write(u32(ncmd) .. u32(scr:frame_number()) .. u32(pc()))
      binf:write(snap())
      ncmd = ncmd + 1
      pending_post = true
      com = { 0, 0, 0, 0 }
    end
    return nil
  end
end

for n = 0, 3 do
  local a = 0x330000 + n * 0x10000
  taps[#taps + 1] = sp:install_write_tap(a, a + 1, "tb_w" .. n, mbox_write(n))
end
taps[#taps + 1] = sp:install_read_tap(0x370000, 0x370001, "tb_st", function(offset, data, mask)
  post_check()
  log("R", "S", data, mask)
  return nil
end)
-- first read / write of the MCU's shared RAM after a command: the MCU has acted by then
taps[#taps + 1] = sp:install_read_tap(MCURAM, MCURAM + 0xffff, "tb_ram_r", function(offset, data, mask)
  if pending_post then
    logf:write(string.format("%d %d %s %06x R M %06x %04x %04x\n", scr:frame_number(), 0, string.format("%.6f", m.time:as_double()):gsub(",", "."), pc(), offset, data, mask))
    post_check()
  end
  return nil
end)

taps[#taps + 1] = sp:install_write_tap(MCURAM, MCURAM + 0xffff, "tb_ram_w", function(offset, data, mask)
  if pending_post then
    logf:write(string.format("%d %d %s %06x W M %06x %04x %04x\n", scr:frame_number(), 0, string.format("%.6f", m.time:as_double()):gsub(",", "."), pc(), offset, data, mask))
    post_check()
  end
  return nil
end)

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
end)

emu.add_machine_stop_notifier(function()
  post_check()
  logf:close()
  binf:close()
  print(string.format("toybox: %d commands", ncmd))
end)
