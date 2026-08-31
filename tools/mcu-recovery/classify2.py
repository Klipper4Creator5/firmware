#!/usr/bin/env python3
"""Split the differing handlers by *cause*, precisely.

The first classifier lumped together two very different things.  The real
discriminator for the allocator phenomenon is the pair (number of
callee-saved registers pushed, stack frame size): stock consistently pushes
FEWER callee-saved registers and compensates with a LARGER frame.  Anything
where those agree but the code still differs is a genuine source
difference, which we can fix without knowing the compiler.
"""
import re
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from classify import collect, strip_regs

CALLEE = re.compile(r'\br(4|5|6|7|8|9|10|11)\b')
PUSH = re.compile(r'^(?:push|stmdb)')
FRAME = re.compile(r'^sub sp, #(\d+)')


def profile(seq):
    saved, frame = 0, 0
    for i in seq:
        if PUSH.match(i):
            saved = len(CALLEE.findall(i))
        m = FRAME.match(i)
        if m:
            frame += int(m.group(1))
    return saved, frame


rows = []
for name, ours, stock in collect():
    if ours == stock:
        continue
    po, ps = profile(ours), profile(stock)
    if strip_regs(ours) == strip_regs(stock):
        kind = 'A register choice only'
    elif ps[0] < po[0] and ps[1] > po[1]:
        kind = 'A stock: fewer regs, bigger frame'
    elif ps[0] != po[0] or ps[1] != po[1]:
        kind = 'B frame differs otherwise'
    else:
        kind = 'C SAME FRAME - source differs'
    rows.append((kind, name, po, ps, len(ours)))

rows.sort()
for kind, name, po, ps, n in rows:
    print("%-34s %-24s %2d insn   ours saved=%d frame=%-3d   stock saved=%d frame=%d"
          % (kind, name, n, po[0], po[1], ps[0], ps[1]))
print()
for k, n in Counter(r[0] for r in rows).most_common():
    print("%3d  %s" % (n, k))
