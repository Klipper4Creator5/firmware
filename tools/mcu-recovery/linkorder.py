#!/usr/bin/env python3
"""Derive the link order FlashForge used, from the stock handler addresses.

Byte-identity needs every function at stock's address, which needs the
object files linked in stock's order.  Each command handler tells us which
source file it came from (via DWARF in our own build) and where it sits in
stock (via command_index[]).  Grouping handlers by file and sorting by
stock address therefore recovers stock's file order directly.
"""
import re
import subprocess
import os
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cmpfuncs as C

TREE = os.environ.get('MCU_TREE', os.path.join(
    os.environ.get('MCU_WORK', 'work/mcu-recovery'), 'klipper'))
C.OURS_ELF = TREE + '/out/klipper.elf'
C.OURS_DICT = TREE + '/out/klipper.dict'
NM = C.NM

# symbol -> source file, from debug info
loc = {}
out = subprocess.run([NM, '-l', '--defined-only', C.OURS_ELF],
                     capture_output=True, text=True).stdout
for line in out.splitlines():
    m = re.match(r'([0-9a-f]+)\s+\S+\s+(\S+)\t(.+?):\d+', line)
    if m:
        f = m.group(3)
        loc[m.group(2)] = f[f.find('src/'):] if 'src/' in f else f

handlers = C.stock_table()
syms = C.our_symbols()

bystock = defaultdict(list)
byours = defaultdict(list)
for name, saddr in handlers.items():
    short = name.split()[0]
    cand = [s for s in syms
            if s == 'command_' + short or s.startswith('command_' + short + '.')]
    if not cand:
        continue
    f = loc.get(cand[0], '?')
    bystock[f].append(saddr)
    byours[f].append(syms[cand[0]][0])

print("%-34s %-22s %-22s" % ('source file', 'stock range', 'our range'))
rows = []
for f in bystock:
    rows.append((min(bystock[f]), max(bystock[f]),
                 min(byours[f]), max(byours[f]), f, len(bystock[f])))
rows.sort()
for lo, hi, olo, ohi, f, n in rows:
    print("%-34s 0x%08X-0x%08X  0x%08X-0x%08X  %2d handlers"
          % (f, lo, hi, olo, ohi, n))

print("\nstock's file order (by first handler):")
for i, r in enumerate(rows):
    print("  %2d. %s" % (i + 1, r[4]))

print("\nour file order (by first handler):")
for i, r in enumerate(sorted(rows, key=lambda r: r[2])):
    print("  %2d. %s" % (i + 1, r[4]))
