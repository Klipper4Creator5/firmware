#!/usr/bin/env python3
"""Classify WHY each differing handler differs.

The question that matters is whether all 20 share one root cause -- a
compiler difference we have not pinned -- or whether some are genuine
source differences we could fix today.

Test: erase register numbers from both instruction streams.  If they then
agree, the only difference is which registers the allocator picked.  If
they still disagree, the code shapes differ and the source is suspect.
"""
import json
import re
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cmpfuncs as C

import os
TREE = os.environ.get('MCU_TREE',
                      os.environ.get('MCU_TREE', os.path.join(
    os.environ.get('MCU_WORK', 'work/mcu-recovery'), 'klipper')))
C.OURS_ELF = TREE + '/out/klipper.elf'
C.OURS_DICT = TREE + '/out/klipper.dict'

REG = re.compile(r'\br\d{1,2}\b')
SPADJ = re.compile(r'\b(?:sub|add)\s+sp\b')


def strip_regs(seq):
    return [REG.sub('rX', i) for i in seq]


def collect():
    d = open(C.STOCK_BIN, 'rb').read()
    stock_end = C.STOCK_BASE + len(d)
    handlers = C.stock_table()
    syms = C.our_symbols()
    ours_cmds = set(json.load(open(C.OURS_DICT))['commands'])
    addrs = sorted(set(handlers.values()))
    out = []
    for name in sorted(handlers):
        if name not in ours_cmds:
            continue
        short = name.split()[0]
        cand = [s for s in syms
                if s == 'command_' + short or s.startswith('command_' + short + '.')]
        if not cand:
            continue
        oaddr, olen = syms[cand[0]]
        saddr = handlers[name]
        nxt = next((a for a in addrs if a > saddr), stock_end)
        slen = min(max(nxt - saddr, 0x400), olen + 64)
        s = [C.norm(i) for i in C.disasm_raw(C.STOCK_BIN, saddr, slen, C.STOCK_BASE)]
        o = [C.norm(i) for i in C.disasm_elf(C.OURS_ELF, oaddr, olen)]
        cut = next((k for k, x in enumerate(o) if x.startswith('.word')), len(o))
        o = o[:cut]
        s = s[:len(o)]
        out.append((short, o, s))
    return out


if __name__ == '__main__':
    rows = []
    for name, ours, stock in collect():
        if ours == stock:
            continue
        if strip_regs(ours) == strip_regs(stock):
            kind = 'REGISTER CHOICE ONLY'
        elif [i.split()[0] for i in ours] == [i.split()[0] for i in stock]:
            kind = 'same opcodes, operands differ'
        else:
            osp = sum(1 for i in ours if SPADJ.search(i))
            ssp = sum(1 for i in stock if SPADJ.search(i))
            if ssp > osp:
                kind = 'stock spills, we do not'
            elif osp > ssp:
                kind = 'we spill, stock does not'
            else:
                kind = 'SHAPE DIFFERS'
        rows.append((kind, name, len(ours), len(stock)))

    rows.sort()
    for kind, name, a, b in rows:
        print("%-31s %-26s ours %3d  stock %3d" % (kind, name, a, b))
    print()
    for k, n in Counter(r[0] for r in rows).most_common():
        print("%3d  %s" % (n, k))
