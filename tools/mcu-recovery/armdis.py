#!/usr/bin/env python3
"""Thumb-2 disassembly of one function out of a raw MCU image, with
literal-pool values resolved and branch targets named where known.

Usage: armdis.py <image.bin> <load-addr> <func-addr> [max-insns]
"""
import sys, struct
from capstone import Cs, CS_ARCH_ARM, CS_MODE_THUMB, CS_MODE_LITTLE_ENDIAN

img, base, addr = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0)
limit = int(sys.argv[4]) if len(sys.argv) > 4 else 120
d = open(img, 'rb').read()
end = base + len(d)
md = Cs(CS_ARCH_ARM, CS_MODE_THUMB | CS_MODE_LITTLE_ENDIAN)
md.detail = True

def word(a):
    return struct.unpack_from('<I', d, a - base)[0] if base <= a < end - 3 else None

def cstr(a, n=48):
    if not (base <= a < end):
        return None
    o = a - base
    s = bytearray()
    while o < len(d) and d[o] and len(s) < n:
        s.append(d[o]); o += 1
    t = s.decode('latin1')
    return t if len(t) > 2 and all(32 <= c < 127 for c in s) else None

off = addr - base
for i in md.disasm(d[off:off + limit * 4], addr):
    note = ''
    op = i.op_str
    # literal pool: "ldr rN, [pc, #imm]"
    if i.mnemonic.startswith('ldr') and '[pc' in op:
        lit = (i.address + 4) & ~3
        imm = int(op.split('#')[1].rstrip(']'), 0)
        v = word(lit + imm)
        if v is not None:
            note = ' ; =0x%08X' % v
            s = cstr(v)
            if s:
                note += ' "%s"' % s
    elif '#0x' in op and i.mnemonic in ('bl', 'b', 'bx', 'blx'):
        note = ''
    print("  %08X  %-8s %s%s" % (i.address, i.mnemonic, op, note))
    if i.mnemonic in ('bx',) and 'lr' in op:
        break
    if i.mnemonic == 'pop' and 'pc' in op:
        break
