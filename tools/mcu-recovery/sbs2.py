#!/usr/bin/env python3
"""Side-by-side one handler, against any build tree.

    sbs2.py <handler> [tree]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import classify

want = sys.argv[1]
for name, ours, stock in classify.collect():
    if name != want:
        continue
    print("%s   ours %d insn   stock %d insn\n" % (name, len(ours), len(stock)))
    print("    %-38s %s" % ('OURS', 'STOCK'))
    for i in range(max(len(ours), len(stock))):
        a = ours[i] if i < len(ours) else ''
        b = stock[i] if i < len(stock) else ''
        print("%-3d %-38s %-34s%s" % (i, a, b, '' if a == b else '  <<<'))
    break
else:
    print("no such handler")
