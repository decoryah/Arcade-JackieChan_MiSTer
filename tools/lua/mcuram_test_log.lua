-- Logs the first accesses of the boot RAM test to mcuram offsets 0x4000 .. 0xffff (address, data, read / write) to see whether the test patterns depend on the address.
local m   = manager.machine
local out = os.getenv("JC_OUT") or "mcuram_test"
local cpu = m.devices[":maincpu"]
local sp  = cpu.spaces["program"]
local MCURAM = 0x300000
local f = io.open(out .. ".txt", "w")
local n = 0
TAPS = {}
local function log(kind)
  return function(offset, data, mask)
    if offset >= MCURAM + 0x4000 and n < 4000 then
      n = n + 1
      f:write(string.format("%s %06x %04x %04x pc %06x\n", kind, offset, data, mask, cpu.state["PC"].value))
      if n % 100 == 0 then f:flush() end
    end
    return nil
  end
end
TAPS[#TAPS + 1] = sp:install_read_tap(MCURAM, MCURAM + 0xffff, "t_r", log("R"))
TAPS[#TAPS + 1] = sp:install_write_tap(MCURAM, MCURAM + 0xffff, "t_w", log("W"))
