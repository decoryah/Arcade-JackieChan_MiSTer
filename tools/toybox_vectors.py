#!/usr/bin/env python3
"""Toybox MCU test vectors for the RTL, from MAME 0.289 itself.

  python tools/toybox_vectors.py <set>            # jchan | jchana | jchan2: generate cases, run MAME's toybox through them, check
                                                  # tools/toybox_model.py against MAME, write work/toybox/<set>.vectors.json (+ .txt)
  python tools/toybox_vectors.py <set> --no-run   # reuse work/toybox/<set>.probe.txt

Two kinds of vectors:
  game   the commands a real boot / game start issues (tools/toybox_capture.py -> <set>.cmds.bin): full 64 KB RAM before / after
  probe  generated cases (all 64 data entries, odd and boundary destinations, DIP values, EEPROM round trips, partial / byte-wide mailbox
         sequences, unknown commands, status reads) driven from Lua (lua/toybox_probe.lua), changed bytes recorded.

The model is considered right only if it reproduces MAME on every case: the report lists mismatches.
"""
import argparse
import json
import os
import random
import subprocess
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402
import toybox_model as T  # noqa: E402

MC = 0x300000
BASE_W = lambda i: (((i * 37) ^ (i >> 8)) ^ 0x5a) & 0xff          # lua/toybox_probe.lua pat()
MBOX = [0x330000, 0x340000, 0x350000, 0x360000]
STATUS = 0x370000


def base_ram():
    return bytearray(BASE_W(i) for i in range(65536))


class Case(object):
    def __init__(self, cid, desc, setup=(), steps=(), dsw=None):
        self.id, self.desc, self.dsw = cid, desc, dsw
        self.setup = list(setup)       # (offset, u16): written through the bus before the case
        self.steps = list(steps)       # ('w16'|'w8'|'r16'|'r8', abs addr, value)


def params(cmd, dest, sub=None):
    s = [(0x10, cmd), (0x12, dest)]
    if sub is not None:
        s.append((0x14, sub))
    return s


def run_cmd():
    """The four mailbox words, in the order the game writes them (2, 3, 0, 1)."""
    return [('w16', MBOX[2], 0xffff), ('w16', MBOX[3], 0xffff), ('w16', MBOX[0], 0xffff), ('w16', MBOX[1], 0xffff)]


def bytes_to_words(offset, data):
    return [(offset + i, (data[i] << 8) | data[i + 1]) for i in range(0, len(data), 2)]


def gen_cases(model):
    cases = []
    rng = random.Random(0x4a43)

    def add(*a, **k):
        cases.append(Case(*a, **k))

    # --- A. EEPROM: save a pattern, load it somewhere else (the model tracks the EEPROM contents from the first save on)
    pats = {
        'zeros': bytes(128), 'ones': bytes([0xff] * 128), 'ramp': bytes(range(128)),
        'aa55': bytes([0xaa, 0x55] * 64), 'rand1': bytes(rng.getrandbits(8) for _ in range(128)),
        'rand2': bytes(rng.getrandbits(8) for _ in range(128)),
    }
    for name, p in pats.items():
        add('save_%s' % name, 'cmd 42: save a 128-byte pattern from 2000', setup=params(0x4200, 0x2000, 0x1234) + bytes_to_words(0x2000, p), steps=run_cmd())
        add('load_%s' % name, 'cmd 02: load the EEPROM to 4000', setup=params(0x0200, 0x4000, 0x0000), steps=run_cmd())
    add('save_odd', 'cmd 42 with an odd destination (rounded down)', setup=params(0x4200, 0x2101) + bytes_to_words(0x2100, pats['rand1']), steps=run_cmd())
    add('load_odd', 'cmd 02 with an odd destination', setup=params(0x0200, 0x4101), steps=run_cmd())
    add('load_end', 'cmd 02 ending exactly at the end of RAM', setup=params(0x0200, 0xff80), steps=run_cmd())
    add('load_end_odd', 'cmd 02 at ff81', setup=params(0x0200, 0xff81), steps=run_cmd())
    add('save_end', 'cmd 42 from the last 128 bytes', setup=params(0x4200, 0xff80) + bytes_to_words(0xff80, pats['rand2']), steps=run_cmd())
    add('load_low', 'cmd 02 over the parameter words', setup=params(0x0200, 0x0000), steps=run_cmd())
    add('load_cmdlow', 'cmd 02 with low command byte set (ignored)', setup=params(0x02ff, 0x4000), steps=run_cmd())
    add('save_cmdlow', 'cmd 42 with low command byte set', setup=params(0x42a5, 0x2000) + bytes_to_words(0x2000, pats['ramp']), steps=run_cmd())

    # --- B. DSW
    for dsw in ('ff00', '0000', '5a00', 'a500', 'db00', '1c00', '8100'):
        for dest in (0x0200, 0x0201, 0xfffe, 0x0000):
            add('dsw_%s_%04x' % (dsw, dest), 'cmd 03 with DIP word %s to %04x' % (dsw, dest), dsw=dsw, setup=params(0x0300, dest), steps=run_cmd())

    # --- C. data directory: every entry, a safe destination
    dd = model.data
    def entry(sub):
        offs = 0x10000 + (sub & 0x3f) * 8
        src = dd[offs + 2] | (dd[offs + 3] << 8)
        ln = dd[offs + 4] | (dd[offs + 5] << 8)
        return src, ln, 0x10000 + src + ln <= len(dd)       # MAME reads outside its data ROM otherwise (undefined): not probed

    model.skipped = []
    for sub in range(64):
        src, ln, inside = entry(sub)
        if not inside:
            model.skipped.append('%02x: src %04x len %04x reads beyond the 128 KB data ROM' % (sub, src, ln))
            continue
        dest = 0x2000 if ln <= 0x8000 else 0
        add('data_%02x' % sub, 'cmd 04 entry %02x (src %04x len %04x)' % (sub, src, ln), setup=params(0x0400, dest, sub), steps=run_cmd())
    for sub in (0x00, 0x05, 0x3f, 0x3d):
        for hi in (0x40, 0x80, 0xc0, 0xff40, 0x1000):
            s2 = hi | sub
            _src, ln, inside = entry(s2)
            if not inside:
                continue
            add('datamask_%04x' % s2, 'cmd 04 sub %04x (only bits 5:0 count)' % s2, setup=params(0x0400, 0x2000 if ln <= 0x8000 else 0, s2), steps=run_cmd())
    for sub in (0x3d, 0x1b, 0x12, 0x24):
        _src, ln, inside = entry(sub)
        if not inside or ln == 0 or ln > 0x8000:
            continue
        add('dataodd_%02x' % sub, 'cmd 04 entry %02x to an odd destination' % sub, setup=params(0x0400, 0x2001, sub), steps=run_cmd())
        add('dataend_%02x' % sub, 'cmd 04 entry %02x ending exactly at the end of RAM' % sub, setup=params(0x0400, 0x10000 - ln, sub), steps=run_cmd())
    add('data_cmdlow', 'cmd 04 with low command byte', setup=params(0x04ff, 0x2000, 0x3d), steps=run_cmd())

    # --- D. other commands: nothing happens (jchan is GAME_NORMAL)
    for c in (0x0000, 0x0100, 0x0500, 0x1000, 0x4300, 0x4400, 0x8200, 0xff00, 0x8300, 0x0600):
        add('other_%04x' % c, 'unknown / ignored command %04x' % c, setup=params(c, 0x2000, 0x3d), steps=run_cmd())

    # --- E. mailbox protocol
    nop = params(0x0000, 0x2000, 0x3d)           # a command that does nothing, to flush the mailbox at the end
    flush = [('w16', MBOX[i], 0xffff) for i in range(4)]
    cmd3 = params(0x0300, 0x1000)                # cmd 03 -> a visible effect at 1000 tells that the command ran
    dswv = 'db00'
    add('mb_order_0123', 'registers in order 0 1 2 3', dsw=dswv, setup=cmd3, steps=[('w16', MBOX[i], 0xffff) for i in range(4)])
    add('mb_order_3210', 'registers in order 3 2 1 0', dsw=dswv, setup=cmd3, steps=[('w16', MBOX[i], 0xffff) for i in (3, 2, 1, 0)])
    add('mb_three', 'only three registers', dsw=dswv, setup=cmd3 + nop, steps=[('w16', MBOX[i], 0xffff) for i in (0, 1, 2)] + flush)
    add('mb_wrong', 'a register holds 0xfffe', dsw=dswv, setup=cmd3, steps=[('w16', MBOX[0], 0xffff), ('w16', MBOX[1], 0xffff), ('w16', MBOX[2], 0xffff), ('w16', MBOX[3], 0xfffe)]
        + [('r16', STATUS, 0)] + [('w16', MBOX[3], 0xffff)])
    add('mb_remember', 'a partial sequence is remembered until it completes', dsw=dswv, setup=cmd3,
        steps=[('w16', MBOX[0], 0xffff), ('w16', MBOX[1], 0xffff), ('w16', MBOX[2], 0xffff), ('r16', STATUS, 0), ('w16', MBOX[3], 0xffff)])
    add('mb_clear', 'writing 0 to a register drops its 0xffff', dsw=dswv, setup=cmd3, steps=[('w16', MBOX[0], 0xffff), ('w16', MBOX[0], 0x0000), ('w16', MBOX[1], 0xffff),
        ('w16', MBOX[2], 0xffff), ('w16', MBOX[3], 0xffff), ('r16', STATUS, 0)] + [('w16', MBOX[0], 0xffff)])
    add('mb_bytes', 'every register written as two bytes', dsw=dswv, setup=cmd3,
        steps=[('w8', MBOX[i] + b, 0xff) for i in (0, 1, 2) for b in (0, 1)] + [('w8', MBOX[3], 0xff), ('r16', STATUS, 0), ('w8', MBOX[3] + 1, 0xff)])
    add('mb_bytes_hi_only', 'only the high bytes', dsw=dswv, setup=cmd3 + nop,
        steps=[('w8', MBOX[i], 0xff) for i in range(4)] + flush)
    add('mb_bytes_mixed', 'one register in two halves, the rest words', dsw=dswv, setup=cmd3,
        steps=[('w16', MBOX[0], 0xffff), ('w16', MBOX[1], 0xffff), ('w16', MBOX[2], 0xffff), ('w8', MBOX[3] + 1, 0xff), ('r16', STATUS, 0), ('w8', MBOX[3], 0xff)])
    add('mb_twice', 'two commands back to back', dsw=dswv, setup=cmd3, steps=run_cmd() + run_cmd())
    add('mb_after', 'one register after completion does not rerun', dsw=dswv, setup=cmd3, steps=run_cmd() + [('w16', MBOX[3], 0xffff)] + flush)
    add('mb_status_reads', 'status reads', steps=[('r16', STATUS, 0), ('r8', STATUS, 0), ('r8', STATUS + 1, 0)])
    return cases


def case_lines(cases):
    out = []
    for c in cases:
        setup = ','.join('%06x:%04x' % (MC + a, v) for a, v in c.setup) or '-'
        steps = ','.join('%s:%06x:%x' % (k, a, v) for k, a, v in c.steps) or '-'
        out.append('%s dsw=%s setup=%s steps=%s' % (c.id, c.dsw or '-', setup, steps))
    return '\n'.join(out) + '\n'


def parse_results(path):
    res = {}
    for line in open(path):
        parts = line.split()
        cid = parts[0]
        ch = parts[1].split('=', 1)[1]
        rd = parts[2].split('=', 1)[1]
        dp = int(parts[3].split('=', 1)[1], 16) if len(parts) > 3 else 0xdb00
        res[cid] = (
            {} if ch == '-' else dict((int(x.split(':')[0], 16), int(x.split(':')[1], 16)) for x in ch.split(',')),
            [] if rd == '-' else [(int(x.split(':')[0], 16), int(x.split(':')[1], 16)) for x in rd.split(',')],
            dp)
    return res


def apply_case(model, case):
    """Run the case through the model starting from base pattern + setup; -> (changed {offset: byte}, reads [(addr, val)])."""
    ram = base_ram()
    for a, v in case.setup:
        ram[a] = v >> 8
        ram[a + 1] = v & 0xff
    before = bytes(ram)
    reads = []
    for kind, a, v in case.steps:
        if kind in ('w16', 'w8'):
            if a in MBOX or (kind == 'w8' and (a & ~1) in MBOX):
                reg = MBOX.index(a & ~1)
                if kind == 'w16':
                    model.mbox_write(reg, v, 0xffff, ram)
                else:
                    model.mbox_write(reg, (v << 8) if not (a & 1) else v, 0xff00 if not (a & 1) else 0x00ff, ram)
            else:
                raise ValueError('step to an unmodelled address %06x' % a)
        elif kind == 'r16':
            reads.append((a, model.status()))
        elif kind == 'r8':
            reads.append((a, model.status() & 0xff))
    changed = dict((i, ram[i]) for i in range(65536) if ram[i] != before[i])
    return changed, reads


def run_probe(setname, cases, frame=700):
    outd = os.path.join(paths.BASE, 'work', 'toybox')
    if not os.path.isdir(outd):
        os.makedirs(outd)
    cf = os.path.join(outd, setname + '.cases.txt')
    rf = os.path.join(outd, setname + '.probe.txt')
    with open(cf, 'w', newline='\n') as f:
        f.write(case_lines(cases))
    if os.path.exists(rf):
        os.remove(rf)
    cwd = os.path.join(paths.BASE, 'work', 'mame')
    env = dict(os.environ, JC_CASES=cf, JC_PROBE_OUT=rf, JC_PROBE_FRAME=str(frame))
    cmd = [paths.MAME, setname, '-rompath', paths.ROMS, '-cfg_directory', 'cfg', '-nvram_directory', 'nvram', '-snapshot_directory', 'snap',
           '-video', 'none', '-sound', 'none', '-nothrottle', '-skip_gameinfo',
           '-autoboot_script', os.path.join(HERE, 'lua', 'toybox_probe.lua'), '-seconds_to_run', str(frame // 50 + 60)]
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, cwd=cwd, env=env)
    if not os.path.exists(rf):
        print(r.stdout[-3000:])
        raise SystemExit('probe produced no result file')
    return rf


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('set')
    ap.add_argument('--no-run', action='store_true')
    a = ap.parse_args(argv)
    mc = open(os.path.join(paths.BASE, 'work', 'rom', a.set + '.mcudata.bin'), 'rb').read()
    model = T.Toybox(mc)
    cases = gen_cases(model)
    rf = os.path.join(paths.BASE, 'work', 'toybox', a.set + '.probe.txt')
    if not a.no_run:
        rf = run_probe(a.set, cases)
    res = parse_results(rf)

    vectors = {'set': a.set, 'mame': '0.289', 'mcudata_crc32': '%08x' % (zlib.crc32(mc) & 0xffffffff), 'skipped_entries': model.skipped, 'probe': [], 'game': []}
    bad = 0
    dsw_ignored = 0
    dsw_values = set()
    for c in cases:
        if c.id not in res:
            print('missing result for', c.id)
            bad += 1
            continue
        mchanged, mreads, mdsw = res[c.id]
        m = T.Toybox(mc)
        m.eeprom = list(model.eeprom)
        m.dsw = mdsw                      # the DIP word MAME's port returned for this case
        if c.dsw and c.dsw != '-' and int(c.dsw, 16) != mdsw:
            dsw_ignored += 1
        changed, reads = apply_case(m, c)
        model.eeprom = m.eeprom
        ok = changed == mchanged and (not mreads or reads == mreads)
        dsw_values.add(mdsw)
        vectors['probe'].append({'id': c.id, 'desc': c.desc, 'dsw': '%04x' % mdsw, 'setup': ['%04x:%04x' % (o, v) for o, v in c.setup],
                                 'steps': ['%s:%06x:%x' % s for s in c.steps],
                                 'changed': ['%04x:%02x' % (k, v) for k, v in sorted(mchanged.items())], 'reads': ['%06x:%x' % r for r in mreads]})
        if not ok:
            bad += 1
            only_m = sorted(set(mchanged) - set(changed))[:6]
            only_p = sorted(set(changed) - set(mchanged))[:6]
            diff = [(hex(k), hex(changed[k]), hex(mchanged[k])) for k in changed if k in mchanged and changed[k] != mchanged[k]][:6]
            print('MISMATCH %-22s model %d bytes, MAME %d bytes; only MAME %s, only model %s, differ %s' % (
                c.id, len(changed), len(mchanged), [hex(x) for x in only_m], [hex(x) for x in only_p], diff))
    # game traces
    capf = os.path.join(paths.BASE, 'work', 'toybox', a.set + '.cmds.bin')
    if os.path.exists(capf):
        d = open(capf, 'rb').read()
        rec = 12 + 2 * 65536
        gm = T.Toybox(mc)
        for k in range(len(d) // rec):
            o = k * rec
            pre = bytearray(d[o + 12:o + 12 + 65536])
            post = d[o + 12 + 65536:o + rec]
            w = (pre[0x10] << 8) | pre[0x11]
            if (w >> 8) == 0x03:
                b = ((pre[0x12] << 8) | pre[0x13]) & ~1
                gm.dsw = (post[b] << 8) | post[b + 1]
            ram = bytearray(pre)
            eeprom_before = list(gm.eeprom)
            gm.com = [0xffff, 0xffff, 0xffff, 0]
            gm.mbox_write(3, 0xffff, 0xffff, ram)
            ok = bytes(ram) == bytes(post)
            if not ok:
                bad += 1
                print('MISMATCH game command %d' % k)
            ch = [(i, post[i]) for i in range(65536) if post[i] != pre[i]]
            vectors['game'].append({'index': k, 'cmd': '%04x' % w, 'dest': '%04x' % ((pre[0x12] << 8) | pre[0x13]), 'sub': '%04x' % ((pre[0x14] << 8) | pre[0x15]),
                                    'frame': struct_u32(d, o + 4), 'pc': '%06x' % struct_u32(d, o + 8),
                                    'params': ['%04x:%02x' % (i, pre[i]) for i in range(0x10, 0x16)],
                                    'dsw': '%04x' % gm.dsw,
                                    'eeprom_before': ['%04x' % x for x in eeprom_before],
                                    'src': ['%02x' % pre[i] for i in range(((pre[0x12] << 8) | pre[0x13]) & ~1, (((pre[0x12] << 8) | pre[0x13]) & ~1) + 0x80)]
                                    if (w >> 8) == 0x42 else None,
                                    'changed': ['%04x:%02x' % c for c in ch], 'model_ok': ok})
    outp = os.path.join(paths.BASE, 'work', 'toybox', a.set + '.vectors.json')
    with open(outp, 'w') as f:
        json.dump(vectors, f, indent=1)
    write_flat(a.set, mc, model, vectors)
    print('DIP words the port returned: %s (%d cases where the requested DIP did not take)' % (' '.join('%04x' % v for v in sorted(dsw_values)), dsw_ignored))
    print('%s: %d probe cases, %d game commands, %d mismatching -> %s' % (a.set, len(vectors['probe']), len(vectors['game']), bad, outp))
    return 1 if bad else 0


def write_flat(setname, mc, model, vectors):
    """work/toybox/<set>.mcudata.dec.bin : the data ROM as the MCU model works on it (decrypted, MAME region byte order)
       work/toybox/<set>.vectors.txt     : flat text for an RTL bench (see the header written below)"""
    d = os.path.join(paths.BASE, 'work', 'toybox')
    with open(os.path.join(d, setname + '.mcudata.dec.bin'), 'wb') as f:
        f.write(bytes(model.data))
    lines = [
        '# toybox vectors, %s, MAME 0.289, mcudata crc32 %s' % (setname, vectors['mcudata_crc32']),
        '# CASE <id>     ; DSW <hex16>  the DIP word the port returns',
        '# SETUP <off16> <val16>  words written to the shared RAM (offset from 300000) before the case; every other byte of the RAM holds',
        '#                       pattern(i) = ((i*37) ^ (i>>8) ^ 0x5a) & 0xff   for byte offset i',
        '# W16|W8 <addr24> <val>  bus write, R16|R8 <addr24>  bus read (the expected value is on a READ line)',
        '# EXPECT <off16> <byte> every byte of the RAM that differs from (pattern + SETUP) afterwards; nothing else changes',
        '# READ <addr24> <val>   value the read must return',
        '# The 93C46 starts erased (ffff) before the first save; it keeps its contents from case to case in file order.',
        '# GAME <index> <cmd> <dest> <sub> <dsw> ; PRE <off16> <byte> (parameter bytes), SRC <128 hex bytes> (cmd 42 only), EE <64 words>',
        '# then EXPECT lines, as above (the rest of the RAM is "whatever the game had": only these bytes change).',
        '',
    ]
    for c in vectors['probe']:
        lines.append('CASE %s' % c['id'])
        lines.append('DSW %s' % c['dsw'])
        for st in c['setup']:
            o, v = st.split(':')
            lines.append('SETUP %s %s' % (o, v))
        for st in c['steps']:
            k, ad, v = st.split(':')
            lines.append('%s %s %s' % (k.upper(), ad, v))
        for r in c['reads']:
            ad, v = r.split(':')
            lines.append('READ %s %s' % (ad, v))
        for ch in c['changed']:
            o, v = ch.split(':')
            lines.append('EXPECT %s %s' % (o, v))
        lines.append('END')
    for g in vectors['game']:
        lines.append('GAME %d %s %s %s %s' % (g['index'], g['cmd'], g['dest'], g['sub'], g['dsw']))
        for pr in g['params']:
            o, v = pr.split(':')
            lines.append('PRE %s %s' % (o, v))
        if g['src']:
            lines.append('SRC %s' % ' '.join(g['src']))
        lines.append('EE %s' % ' '.join(g['eeprom_before']))
        for ch in g['changed']:
            o, v = ch.split(':')
            lines.append('EXPECT %s %s' % (o, v))
        lines.append('END')
    with open(os.path.join(d, setname + '.vectors.txt'), 'w', newline='\n') as f:
        f.write('\n'.join(lines) + '\n')


def struct_u32(d, o):
    return d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
