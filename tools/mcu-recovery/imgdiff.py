#!/usr/bin/env python3
"""Whole-image byte comparison against stock.

Now that the two images are within tens of bytes of each other and the
vector table matches exactly, a positional diff is finally meaningful: it
shows where the layouts first part company and how much agrees overall.
"""
import os
import sys

STOCK = os.environ.get('STOCK_BIN', 'work/stock/mcu/levelBoard.bin')
OURS = sys.argv[1] if len(sys.argv) > 1 else \
    os.path.join(os.environ.get('MCU_TREE', 'work/mcu-recovery/klipper'), 'out/klipper.bin')
BASE = 0x08004000

s = open(STOCK, 'rb').read()
o = open(OURS, 'rb').read()
n = min(len(s), len(o))
print("stock %d bytes   ours %d bytes   delta %+d" % (len(s), len(o), len(o) - len(s)))

first = next((i for i in range(n) if s[i] != o[i]), None)
if first is None:
    print("identical over the common %d bytes" % n)
else:
    print("first differing byte at 0x%08X (offset 0x%X)" % (BASE + first, first))

eq = sum(1 for i in range(n) if s[i] == o[i])
print("bytes equal at the same offset: %d / %d  (%.1f%%)" % (eq, n, 100.0 * eq / n))

# Longest runs of agreement, to show which regions are already solid.
runs, start = [], None
for i in range(n):
    if s[i] == o[i]:
        if start is None:
            start = i
    else:
        if start is not None and i - start >= 64:
            runs.append((i - start, start, i))
        start = None
if start is not None and n - start >= 64:
    runs.append((n - start, start, n))
runs.sort(reverse=True)
print("\nlongest matching runs (>=64 bytes):")
for ln, a, b in runs[:12]:
    print("  %6d bytes  0x%08X .. 0x%08X" % (ln, BASE + a, BASE + b))
print("  (%d runs total, %d bytes in them)" % (len(runs), sum(r[0] for r in runs)))
