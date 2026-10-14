-- Drive MAME's toybox MCU with generated cases and record exactly which bytes of its shared RAM change (tools/toybox_vectors.py makes the cases
-- and checks the results against tools/toybox_model.py).
--
--   JC_CASES        case file (text), JC_PROBE_OUT result file, JC_PROBE_FRAME frame at which to start (default 700: the game is idling)
--
-- case file, one case per line:
--     <id> dsw=<hex or -> setup=<addr>:<val16>,... steps=<kind>:<addr>:<val>,...
--   kinds: w16 / w8 (bus write), r16 / r8 (bus read; val ignored).  addr is absolute (300000-30ffff = the MCU's shared RAM).
-- result file:   <id> changed=<addr>:<byte>,...  reads=<addr>:<val>,...  dswport=<hex>
--
-- A case runs inside one frame-done callback, i.e. between CPU timeslices: the game cannot interleave.  A change of the DIP switches is applied in
-- the callback BEFORE the case's frame (the I/O port takes new DIP values at its next frame update), so such a case runs one frame later.
-- The shared RAM is first filled with a position-dependent pattern; after each case the changed bytes and the setup words are put back.
local m      = manager.machine
local sp     = m.devices[":maincpu"].spaces["program"]
local scr    = m.screens[":screen"]
local casefn = assert(os.getenv("JC_CASES"))
local outfn  = assert(os.getenv("JC_PROBE_OUT"))
local at     = tonumber(os.getenv("JC_PROBE_FRAME") or "700")
local MC     = 0x300000

local function pat(i) return (((i * 37) ~ (i >> 8)) ~ 0x5a) & 0xff end

local function parse_list(s)
  local t = {}
  if s and s ~= "-" then
    for item in string.gmatch(s, "[^,]+") do
      local parts = {}
      for p in string.gmatch(item, "[^:]+") do parts[#parts + 1] = p end
      t[#t + 1] = parts
    end
  end
  return t
end

local function set_dsw(v)
  local port = m.ioport.ports[":DSW1"]
  for _, f in pairs(port.fields) do
    f.user_value = v & f.mask
  end
end

local cases, ci, out, started, applied, finished = {}, 1, nil, false, nil, false
for line in io.lines(casefn) do
  local id = line:match("^(%S+)")
  if id then
    cases[#cases + 1] = {
      id = id,
      dsw = line:match("dsw=(%S+)"),
      setup = parse_list(line:match("setup=(%S+)")),
      steps = parse_list(line:match("steps=(%S+)")),
    }
  end
end

local function run_case(c)
  local touched = {}
  for _, s in ipairs(c.setup) do
    local a, v = tonumber(s[1], 16), tonumber(s[2], 16)
    sp:write_u16(a, v)
    touched[a & ~1] = true
  end
  local before = {}
  for i = 0, 0xffff, 2 do before[i] = sp:read_u16(MC + i) end

  local reads = {}
  for _, s in ipairs(c.steps) do
    local kind, a, v = s[1], tonumber(s[2], 16), tonumber(s[3] or "0", 16)
    if kind == "w16" then sp:write_u16(a, v)
    elseif kind == "w8" then sp:write_u8(a, v)
    elseif kind == "r16" then reads[#reads + 1] = string.format("%06x:%04x", a, sp:read_u16(a))
    elseif kind == "r8" then reads[#reads + 1] = string.format("%06x:%02x", a, sp:read_u8(a))
    end
  end

  local changed = {}
  for i = 0, 0xffff, 2 do
    local w = sp:read_u16(MC + i)
    local b = before[i]
    if w ~= b then
      if (w >> 8) ~= (b >> 8) then changed[#changed + 1] = string.format("%04x:%02x", i, w >> 8) end
      if (w & 0xff) ~= (b & 0xff) then changed[#changed + 1] = string.format("%04x:%02x", i + 1, w & 0xff) end
      touched[MC + i] = true
    end
  end
  local dswport = m.ioport.ports[":DSW1"]:read()
  out:write(string.format("%s changed=%s reads=%s dswport=%04x\n", c.id, #changed > 0 and table.concat(changed, ",") or "-",
    #reads > 0 and table.concat(reads, ",") or "-", dswport))
  out:flush()

  for a, _ in pairs(touched) do
    local i = a - MC
    sp:write_u16(a, (pat(i) << 8) | pat(i + 1))
  end
end

emu.register_frame_done(function()
  if finished or scr:frame_number() < at then return end
  if not started then
    started = true
    out = assert(io.open(outfn, "w"))
    for i = 0, 0xffff, 2 do
      sp:write_u16(MC + i, (pat(i) << 8) | pat(i + 1))
    end
  end
  while ci <= #cases do
    local c = cases[ci]
    if c.dsw and c.dsw ~= "-" and c.dsw ~= applied then
      set_dsw(tonumber(c.dsw, 16))
      applied = c.dsw
      return                         -- the new DIP value is live from the next frame
    end
    run_case(c)
    ci = ci + 1
  end
  finished = true
  out:close()
  print(string.format("toybox probe: %d cases", #cases))
  m:exit()
end)
