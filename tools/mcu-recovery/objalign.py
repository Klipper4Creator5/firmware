#!/usr/bin/env python3
"""Best alignment of a symbol from an object file within the stock image.

    objalign.py <obj> <symbol> [label]

Used as a toolchain oracle: __udivmoddi4 is prebuilt libgcc, so if it does
not match stock, the toolchain is wrong -- no source or -f flag can change
it. One objdump per candidate, no firmware build needed.
"""
import re
import subprocess
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cmpfuncs as C

INSN = re.compile(r'\s*([0-9a-f]+):\s+([0-9a-f ]+)\t(\S+)\s*(.*)')

_cache = {}


def stock_stream():
    if 'v' not in _cache:
        raw = subprocess.run(
            [C.OBJDUMP, '-D', '-b', 'binary', '-m', 'arm', '-M', 'force-thumb',
             '--adjust-vma=0x%x' % C.STOCK_BASE, C.STOCK_BIN],
            capture_output=True, text=True).stdout
        a, s = [], []
        for line in raw.splitlines():
            m = INSN.match(line)
            if m:
                a.append(int(m.group(1), 16))
                s.append(C.norm((m.group(3), m.group(4))))
        _cache['v'] = (a, s)
    return _cache['v']


obj, sym = sys.argv[1], sys.argv[2]
label = sys.argv[3] if len(sys.argv) > 3 else obj

out = subprocess.run([C.OBJDUMP, '-d', '--disassemble=' + sym, obj],
                     capture_output=True, text=True).stdout
o = [C.norm((m.group(3), m.group(4)))
     for m in (INSN.match(l) for l in out.splitlines()) if m]
cut = next((k for k, x in enumerate(o) if x.startswith('.word')), len(o))
o = o[:cut]
if not o:
    print("%-46s  symbol not found" % label)
    sys.exit(0)

addrs, stock = stock_stream()
best = (0, 0)
for i in range(len(stock) - 4):
    eq = sum(1 for a, b in zip(o, stock[i:i + len(o)]) if a == b)
    if eq > best[0]:
        best = (eq, i)
eq, i = best
pre = 0
while pre < len(o) and i + pre < len(stock) and o[pre] == stock[i + pre]:
    pre += 1
print("%-46s %3d insn  best %3d/%3d (%3.0f%%)  prefix %2d  at 0x%08X%s"
      % (label, len(o), eq, len(o), 100.0 * eq / len(o), pre, addrs[i],
         "   <== MATCH" if eq == len(o) else ""))
