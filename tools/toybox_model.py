#!/usr/bin/env python3
"""Golden model of the Kaneko "toybox" MCU as MAME 0.289 emulates it (kaneko_toybox.cpp), seen from the 68000 side.

Everything is in the 68000's own byte order: `ram` is the MCU's shared RAM (main CPU 300000-30ffff) as 65536 bytes, byte i = the byte at
300000 + i.  The MAME code works on a u16 array and casts it to bytes; on a little-endian host the C++ byte index i is the 68000 byte
at address (i ^ 1).  That is the one non-obvious thing in this file, and the test vectors (tools/toybox_vectors.py) prove it.

  mailbox   four 16-bit words, written at 330000 / 340000 / 350000 / 360000.  Writes are merged by the bus mask (COMBINE_DATA).  When all four
            hold 0xffff the command runs and the four words are cleared (so a partial sequence is remembered until it completes).
  params    ram word at +0x10 (command, only the high byte counts), +0x12 (destination byte offset), +0x14 (sub-command, cmd 04 only)
  status    370000 reads 0 always

  cmd 02    load : the 64 words of the 93C46 -> ram[dest & ~1 ...], each word byte-swapped w.r.t. the EEPROM word
  cmd 42    save : ram[dest & ~1 ...] (128 bytes) -> the 93C46, each word byte-swapped back
  cmd 03    DSW  : the 16-bit DSW1 port value -> ram word at (dest & ~1)
  cmd 04    data : directory entry at mcudata[0x10000 + (sub & 0x3f) * 8] = {u16 unused, u16 src, u16 len, u16 extra}, little endian over the
                   *decrypted, byte-swapped* data ROM; len bytes of mcudata[0x10000 + src ...] -> 68000 bytes (dest + x) ^ 1   (dest not rounded)
  cmd 43    only Bonk's Adventure (ignored by jchan)
  other     nothing

mcudata (jcd0x2.u13 etc., 128 KB) as MAME holds it: ROM_LOAD16_WORD_SWAP (byte i of the region = file byte i ^ 1), then
region[i] += table[(i ^ 1) & 0xff] for every byte (decryption_table, kaneko_toybox.cpp).
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402


def parse_tables(path=None):
    path = path or os.path.join(paths.MAME_SRC, 'kaneko_toybox.cpp')
    text = open(path, encoding='utf-8', errors='replace').read()
    out = {}
    for name in ('decryption_table', 'decryption_table_alt'):
        m = re.search(r'static const uint8_t %s\[0x100\]\s*=\s*\{(.*?)\};' % name, text, re.S)
        vals = [int(x, 16) for x in re.findall(r'0x([0-9a-fA-F]{1,2})', m.group(1))]
        assert len(vals) == 256, (name, len(vals))
        out[name] = vals
    return out


def decrypt_mcudata(region, table):
    """region = MAME's "mcudata" region image (as built by jchan_rom.py: word-swapped file), -> the bytes the device works on."""
    return bytearray(((region[i] + table[(i ^ 1) & 0xff]) & 0xff) for i in range(len(region)))


class Toybox(object):
    def __init__(self, mcudata_region, table_name='decryption_table', dsw=0xdb00, eeprom=None):
        self.data = decrypt_mcudata(mcudata_region, parse_tables()[table_name])
        self.dsw = dsw
        self.eeprom = list(eeprom) if eeprom is not None else [0xffff] * 64
        self.com = [0, 0, 0, 0]
        self.log = []

    # ---- bus side
    def mbox_write(self, reg, data, mask, ram):
        """One 68000 write to mailbox register `reg`; runs the command on the fourth 0xffff.  Returns the command executed (or None)."""
        self.com[reg] = (self.com[reg] & ~mask & 0xffff) | (data & mask)
        if all(c == 0xffff for c in self.com):
            self.com = [0, 0, 0, 0]
            return self.run(ram)
        return None

    @staticmethod
    def status():
        return 0

    # ---- the MCU
    def run(self, ram):
        w = lambda a: (ram[a] << 8) | ram[a + 1]
        cmd, dest, sub = w(0x10), w(0x12), w(0x14)
        hi = cmd >> 8
        base = dest & ~1                       # mcu_offset = dest / 2 words
        if hi == 0x02:
            for i in range(0, 0x80, 2):
                dat = self.eeprom[i // 2]
                ram[base + i] = dat & 0xff     # host byte (base+i) = dat >> 8 sits at 68000 address ^1
                ram[base + i + 1] = dat >> 8
        elif hi == 0x42:
            for i in range(0, 0x80, 2):
                self.eeprom[i // 2] = (ram[base + i + 1] << 8) | ram[base + i]
        elif hi == 0x03:
            ram[base] = (self.dsw >> 8) & 0xff
            ram[base + 1] = self.dsw & 0xff
        elif hi == 0x04:
            d = self.data
            offs = 0x10000 + (sub & 0x3f) * 8
            src = d[offs + 2] | (d[offs + 3] << 8)
            ln = d[offs + 4] | (d[offs + 5] << 8)
            for x in range(ln):
                ram[(dest + x) ^ 1] = d[0x10000 + src + x]      # src is relative to the same 0x10000 base as the directory
        return hi


def main(argv):
    import struct
    import jchan_rom
    setname = argv[0] if argv else 'jchan'
    mc = open(os.path.join(paths.BASE, 'work', 'rom', setname + '.mcudata.bin'), 'rb').read()
    tb = Toybox(mc)
    d = open(os.path.join(paths.BASE, 'work', 'toybox', setname + '.cmds.bin'), 'rb').read()
    rec = 12 + 2 * 65536
    bad = 0
    for k in range(len(d) // rec):
        o = k * rec
        pre = bytearray(d[o + 12:o + 12 + 65536])
        post = d[o + 12 + 65536:o + rec]
        tb.com = [0xffff, 0xffff, 0xffff, 0]
        tb.dsw = None
        # DSW: take what MAME did for cmd 03
        w = (pre[0x10] << 8) | pre[0x11]
        if (w >> 8) == 0x03:
            b = ((pre[0x12] << 8) | pre[0x13]) & ~1
            tb.dsw = (post[b] << 8) | post[b + 1]
        if (w >> 8) == 0x02 and k == 4:
            pass
        ram = bytearray(pre)
        tb.mbox_write(3, 0xffff, 0xffff, ram)
        ok = bytes(ram) == bytes(post)
        print('cmd %2d  %04x dest=%04x sub=%04x  model == MAME: %s' % (k, w, (pre[0x12] << 8) | pre[0x13], (pre[0x14] << 8) | pre[0x15], ok))
        bad += 0 if ok else 1
    print('%d mismatching commands' % bad)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
