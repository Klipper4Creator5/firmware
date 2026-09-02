#!/usr/bin/env python3
"""Compare our vector table against stock's, slot by slot.

Takes our .bin path as argv[1].  Classifies each slot rather than comparing
addresses, since the two images have different layouts: what must agree is
which slots hold a real handler, which hold the default, and how long the
table is.
"""
import os
import struct
import subprocess
import sys

STOCK = os.environ.get('STOCK_BIN', 'work/stock/mcu/levelBoard.bin')
OURS = sys.argv[1]
ELF = sys.argv[2] if len(sys.argv) > 2 else None
TC = os.environ.get('MCU_TOOLCHAIN', '')
TC = TC + '/bin/' if TC else ''
STOCK_DEFAULT = 0x08008921

syms = {}
if ELF:
    out = subprocess.run([TC + 'arm-none-eabi-nm', ELF],
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        p = line.split()
        if len(p) == 3:
            syms[int(p[0], 16) | 1] = p[2]

s = open(STOCK, 'rb').read()
o = open(OURS, 'rb').read()

our_default = None
ow = struct.unpack_from('<80I', o, 0)
# our DefaultHandler is whatever value repeats most in the table body
from collections import Counter
our_default = Counter(ow[16:60]).most_common(1)[0][0]

print("stock default 0x%08X   ours 0x%08X" % (STOCK_DEFAULT, our_default))


def kind(w, default):
    if w == default:
        return 'default'
    if w == 0:
        return '-'
    return 'HANDLER'


def tablen(buf, default):
    w = struct.unpack_from('<80I', buf, 0)
    n = 0
    for i, x in enumerate(w):
        if i == 0 or x == default or x == 0 or (x & 1 and 0x08004000 <= x < 0x0800c000):
            n = i + 1
        else:
            break
    return n


ns, no = tablen(s, STOCK_DEFAULT), tablen(o, our_default)
print("table words: stock %d (irq 0..%d)   ours %d (irq 0..%d)"
      % (ns, ns - 17, no, no - 17))

sw = struct.unpack_from('<80I', s, 0)
bad = 0
for i in range(16, max(ns, no)):
    a = kind(sw[i], STOCK_DEFAULT) if i < ns else 'ABSENT'
    b = kind(ow[i], our_default) if i < no else 'ABSENT'
    if a != b:
        bad += 1
        name = syms.get(ow[i], '') if i < no else ''
        print("  irq%-3d stock %-8s ours %-8s %s" % (i - 16, a, b, name))
print("mismatched slots: %d" % bad)
