#!/usr/bin/env python3
"""Every FlashForge shutdown() error code in the stock levelBoard image.

Keys off the literal-pool loads of the error-code global (0x20000124): find
each `ldr rX, =0x20000124`, then scan forward in the same neighbourhood for
`str rY, [rX]` and recover the constant put into rY.
"""
import re
import subprocess

T = '/home/oleksandr/.claude/jobs/885c1997/tmp'
OBJDUMP = T + '/gcc-arm-none-eabi-10.3-2021.10/bin/arm-none-eabi-objdump'
BIN = '/home/oleksandr/workspace/firmware/work/stock/mcu/levelBoard.bin'
BASE = 0x08004000
ERR = 0x20000124

data = open(BIN, 'rb').read()


def word(a):
    o = a - BASE
    return int.from_bytes(data[o:o+4], 'little')


def cstr(a):
    o = a - BASE
    if not (0 <= o < len(data)):
        return None
    e = data.find(b'\0', o)
    s = data[o:e]
    try:
        t = s.decode('ascii')
    except UnicodeDecodeError:
        return None
    return t if len(t) > 3 and all(32 <= c < 127 for c in s) else None


out = subprocess.run(
    [OBJDUMP, '-D', '-b', 'binary', '-m', 'arm', '-M', 'force-thumb',
     '--adjust-vma=0x%x' % BASE, BIN], capture_output=True, text=True).stdout

ins = []
for line in out.splitlines():
    m = re.match(r'\s*([0-9a-f]+):\s+([0-9a-f ]+)\t(\S+)\s*(.*)', line)
    if m:
        ops = m.group(4)
        lit = None
        c = re.search(r';\s*\((0x[0-9a-f]+)\)', ops)
        if c:
            lit = int(c.group(1), 16)
        ops = re.sub(r'\s*;.*$', '', ops).strip()
        ins.append((int(m.group(1), 16), m.group(3), ops, lit))

hits = []
for i, (addr, mn, ops, lit) in enumerate(ins):
    if not (mn.startswith('ldr') and lit is not None and word(lit) == ERR):
        continue
    reg = ops.split(',')[0].strip()
    # forward scan for the store through this register
    for j in range(i + 1, min(i + 14, len(ins))):
        a2, m2, o2, l2 = ins[j]
        sm = re.match(r'(r\d+), \[' + reg + r'(?:, #0)?\]$', o2)
        if m2.startswith('str') and sm:
            src = sm.group(1)
            code = msg = None
            # the constant and the message are set near the store
            for k in range(max(0, j - 8), min(j + 3, len(ins))):
                a3, m3, o3, l3 = ins[k]
                if m3 in ('movs', 'mov.w', 'movw') and o3.startswith(src + ', #'):
                    code = int(o3.split('#')[1], 0)
                if m3.startswith('ldr') and l3 is not None:
                    s = cstr(word(l3))
                    if s:
                        msg = s
            hits.append((a2, code, msg))
            break

seen = {}
for a, c, m in sorted(hits, key=lambda h: (h[1] is None, h[1] or 0)):
    print("0x%08X  code=%-5s %s" % (a, c if c is not None else '??', m or '(?)'))
    if c is not None:
        seen[c] = m
print("\n%d sites, %d resolved codes" % (len(hits), len(seen)))
missing = [c for c in range(1, max(seen) + 1) if c not in seen]
print("unused codes below max: %s" % missing)
