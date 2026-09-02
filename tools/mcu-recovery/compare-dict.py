#!/usr/bin/env python3
"""Compare a rebuilt Klipper dictionary against a stock one.

The gate is the *message set* plus every config constant and enumeration.
Message ids are reported but not gated: Klipper assigns them from the
order the compile-time-request entries land in the image, the host learns
them from the dictionary at run time, and two builds that disagree only
on numbering still speak the same protocol.

    compare-dict.py <rebuilt.dict> <stock.dict.json>
"""
import json
import sys


def main():
    mine = json.load(open(sys.argv[1]))
    stock = json.load(open(sys.argv[2]))
    bad = False

    for key in ('commands', 'responses'):
        a, b = set(mine.get(key, {})), set(stock.get(key, {}))
        if a != b:
            bad = True
            for x in sorted(a - b):
                print("   only in rebuilt: %s" % x)
            for x in sorted(b - a):
                print("   only in stock:   %s" % x)
        print("%-10s %d rebuilt, %d stock, %d shared"
              % (key, len(a), len(b), len(a & b)))

    for key in ('config', 'enumerations'):
        a, b = mine.get(key, {}), stock.get(key, {})
        for k in sorted(set(a) | set(b)):
            if a.get(k) != b.get(k):
                bad = True
                print("   %s %-24s rebuilt=%r stock=%r"
                      % (key, k, a.get(k), b.get(k)))
        if a == b:
            print("%-10s identical (%d entries)" % (key, len(b)))

    ids = sum(1 for k, v in stock.get('commands', {}).items()
              if mine.get('commands', {}).get(k) != v)
    if ids:
        print("note: %d of %d commands carry a different message id "
              "(not gated -- see the docstring)"
              % (ids, len(stock.get('commands', {}))))

    print("dictionary %s the stock firmware"
          % ("DIFFERS from" if bad else "matches"))
    return 1 if bad else 0


sys.exit(main())
