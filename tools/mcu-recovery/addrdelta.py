#!/usr/bin/env python3
"""How far is each handler from its stock address?

Once the ordering is right, the useful progress metric is no longer "what
percentage of bytes coincide" -- a single extra byte early in the image
shifts everything after it and drives that to nearly zero. What matters is
how many functions sit at exactly stock's address, and how large the
remaining drift is.
"""
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cmpfuncs as C

TREE = sys.argv[1] if len(sys.argv) > 1 else \
    os.environ.get('MCU_TREE', os.path.join(
    os.environ.get('MCU_WORK', 'work/mcu-recovery'), 'klipper'))
C.OURS_ELF = TREE + '/out/klipper.elf'
C.OURS_DICT = TREE + '/out/klipper.dict'

handlers = C.stock_table()
syms = C.our_symbols()
rows = []
for name, saddr in handlers.items():
    short = name.split()[0]
    cand = [s for s in syms
            if s == 'command_' + short or s.startswith('command_' + short + '.')]
    if cand:
        rows.append((saddr, syms[cand[0]][0], short))
rows.sort()

exact = 0
print("%-28s %-12s %-12s %s" % ('handler', 'stock', 'ours', 'delta'))
for sa, oa, nm in rows:
    d = oa - sa
    if d == 0:
        exact += 1
    print("%-28s 0x%08X  0x%08X  %+d" % (nm, sa, oa, d))

deltas = [oa - sa for sa, oa, _ in rows]
print("\n%d of %d handlers at exactly stock's address" % (exact, len(rows)))
print("drift: min %+d  max %+d  median %+d"
      % (min(deltas), max(deltas), sorted(deltas)[len(deltas) // 2]))
print("most common drifts: %s"
      % ', '.join("%+d (x%d)" % (v, n) for v, n in Counter(deltas).most_common(6)))
