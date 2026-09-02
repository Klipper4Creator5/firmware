#!/usr/bin/env python3
"""How much of the firmware is instruction-exact, function by function?

The handler gate covers 54 functions. The image has far more. For each
function in our build, ask whether its normalised instruction sequence
occurs anywhere in the stock image. That answers "have we recovered this
code", independently of where it was placed.
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

INSN = re.compile(r'\s*([0-9a-f]+):\s+([0-9a-f ]+)\t(\S+)\s*(.*)')

# stock, as one normalised stream
stock = [C.norm((m.group(3), m.group(4))) for m in
         (INSN.match(l) for l in subprocess.run(
             [C.OBJDUMP, '-D', '-b', 'binary', '-m', 'arm', '-M', 'force-thumb',
              '--adjust-vma=0x%x' % C.STOCK_BASE, C.STOCK_BIN],
             capture_output=True, text=True).stdout.splitlines()) if m]
index = defaultdict(list)
for i, x in enumerate(stock):
    index[x].append(i)

# ours, grouped by function
out = subprocess.run([C.OBJDUMP, '-d', C.OURS_ELF],
                     capture_output=True, text=True).stdout
funcs, cur, name = {}, [], None
for line in out.splitlines():
    m = re.match(r'^([0-9a-f]+) <(.+)>:', line)
    if m:
        if name and cur:
            funcs[name] = cur
        name, cur = m.group(2), []
        continue
    m = INSN.match(line)
    if m and name:
        cur.append(C.norm((m.group(3), m.group(4))))
if name and cur:
    funcs[name] = cur

exact = missing = 0
exact_b = total_b = 0
misses = []
for nm, seq in sorted(funcs.items()):
    cut = next((k for k, x in enumerate(seq) if x.startswith('.word')), len(seq))
    seq = seq[:cut]
    if len(seq) < 2:
        continue
    total_b += len(seq)
    hit = any(stock[i:i + len(seq)] == seq for i in index.get(seq[0], []))
    if hit:
        exact += 1
        exact_b += len(seq)
    else:
        missing += 1
        misses.append((len(seq), nm))

print("functions compared: %d" % (exact + missing))
print("  instruction-exact somewhere in stock: %d" % exact)
print("  not found:                            %d" % missing)
print("instructions: %d of %d in exact functions (%.1f%%)"
      % (exact_b, total_b, 100.0 * exact_b / total_b))
misses.sort(reverse=True)
print("\nlargest functions still unmatched:")
for n, nm in misses[:20]:
    print("  %4d insn  %s" % (n, nm))
