#!/usr/bin/env python3
"""Find literal-pool references to an address and the function each sits in."""
import sys, struct
img, base, target = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0)
d = open(img, 'rb').read()
hits = [o for o in range(0, len(d) - 4, 4)
        if struct.unpack_from('<I', d, o)[0] == target]
print("literal 0x%08X referenced from %d pool slot(s):" % (target, len(hits)))
for o in hits:
    # walk back to a plausible prologue (push {...,lr} = 0xB5xx or 0xE92D....)
    start = None
    for b in range(o, max(0, o - 0x600), -2):
        hw = struct.unpack_from('<H', d, b)[0]
        if (hw & 0xFE00) == 0xB400 and (hw & 0x0100):      # push {..., lr}
            start = b; break
        if hw == 0xE92D or (hw & 0xFFF0) == 0xE920:        # push.w
            start = b; break
    print("  pool@0x%08X   nearest prologue 0x%08X" %
          (base + o, base + start if start is not None else 0))
