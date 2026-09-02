#!/usr/bin/env python3
"""Compare one of our functions against a stock address.

    fncmp.py <our-symbol> <stock-addr-hex> [-v]

Uses the same normalisation and the same whole-image disassembly as
cmpfuncs.py, so its verdicts are consistent with the handler gate.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cmpfuncs as C

TREE = os.environ.get('MCU_TREE', os.path.join(
    os.environ.get('MCU_WORK', 'work/mcu-recovery'), 'klipper'))
C.OURS_ELF = TREE + '/out/klipper.elf'
C.OURS_DICT = TREE + '/out/klipper.dict'

sym = sys.argv[1]
saddr = int(sys.argv[2], 16)
verbose = '-v' in sys.argv

syms = C.our_symbols()
if sym not in syms:
    cand = [s for s in syms if s.startswith(sym)]
    if not cand:
        print("no symbol %s" % sym)
        sys.exit(1)
    sym = cand[0]
oaddr, olen = syms[sym]

o = [C.norm(i) for i in C.disasm_elf(C.OURS_ELF, oaddr, olen)]
cut = next((k for k, x in enumerate(o) if x.startswith('.word')), len(o))
o = o[:cut]
s = [C.norm(i) for i in C.disasm_raw(C.STOCK_BIN, saddr, olen + 64, C.STOCK_BASE)]
s = s[:len(o)]

pre = 0
while pre < min(len(o), len(s)) and o[pre] == s[pre]:
    pre += 1
eq = sum(1 for a, b in zip(o, s) if a == b)
print("%s  ours 0x%08X (%d insn)  stock 0x%08X   prefix %d, %d/%d equal%s"
      % (sym, oaddr, len(o), saddr, pre, eq, len(o),
         "   EXACT" if pre == len(o) and o else ""))
if verbose and pre < len(o):
    for i in range(max(len(o), len(s))):
        a = o[i] if i < len(o) else ''
        b = s[i] if i < len(s) else ''
        print("%-3d %-36s %-34s%s" % (i, a, b, '' if a == b else '  <<<'))
