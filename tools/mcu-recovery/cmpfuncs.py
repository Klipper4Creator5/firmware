#!/usr/bin/env python3
"""Compare each command handler in our build against the stock image.

Both sides are disassembled with the same binutils.  Absolute operands are
normalised away (the two images have different layouts), so what is compared
is the instruction stream: mnemonics, registers and non-address immediates.
"""
import json
import re
import subprocess
import sys

# Paths come from the environment so this runs against any build tree.
#   MCU_WORK   the build dir used by build.sh (default work/mcu-recovery)
#   STOCK_BIN / STOCK_DICT   the stock image and its extracted dictionary
import os

ROOT = os.environ.get('MCU_ROOT', os.getcwd())
WORK = os.environ.get('MCU_WORK', os.path.join(ROOT, 'work/mcu-recovery'))
TC = os.environ.get('MCU_TOOLCHAIN',
                    os.path.join(WORK, 'gcc-arm-none-eabi-10.3-2021.10'))
OBJDUMP = os.path.join(TC, 'bin/arm-none-eabi-objdump')
NM = os.path.join(TC, 'bin/arm-none-eabi-nm')
OURS_ELF = os.environ.get('OURS_ELF', os.path.join(WORK, 'klipper/out/klipper.elf'))
OURS_DICT = os.environ.get('OURS_DICT', os.path.join(WORK, 'klipper/out/klipper.dict'))
STOCK_BIN = os.environ.get('STOCK_BIN',
                           os.path.join(ROOT, 'work/stock/mcu/levelBoard.bin'))
STOCK_DICT = os.environ.get('STOCK_DICT',
                            os.path.join(ROOT, 'work/stock/mcu/levelBoard.dict.json'))
STOCK_BASE = 0x08004000
STOCK_TABLE = 0x0800A35C

HEX = re.compile(r'\b(?:0x)?[0-9a-f]{5,}\b')
NUM = re.compile(r'\b\d{5,}\b')


def norm(insn):
    """Drop absolute addresses so two layouts can still be compared."""
    op = insn[1]
    op = HEX.sub('A', op)
    op = NUM.sub('A', op)
    op = re.sub(r'\s*;.*$', '', op)
    op = re.sub(r'<[^>]*>', '', op)
    # pc-relative literal offsets follow the pool layout, not the code
    op = re.sub(r'\[pc, #\d+\]', '[pc, #A]', op)
    return insn[0] + ' ' + op.strip()


_RAW_CACHE = {}


def _disasm_whole(path, vma):
    """Disassemble a flat binary once, returning [(addr, mnemonic, ops)].

    Slicing this in Python replaces per-function --start-address calls,
    which cannot be trusted: for some addresses objdump emits nothing at
    all from a `-b binary` image even though neighbouring addresses work.
    """
    key = (path, vma)
    if key in _RAW_CACHE:
        return _RAW_CACHE[key]
    out = subprocess.run(
        [OBJDUMP, '-D', '-b', 'binary', '-m', 'arm', '-M', 'force-thumb',
         '--adjust-vma=0x%x' % vma, path],
        capture_output=True, text=True).stdout
    seq = []
    for line in out.splitlines():
        m = re.match(r'\s*([0-9a-f]+):\s+([0-9a-f ]+)\t(\S+)\s*(.*)', line)
        if m:
            seq.append((int(m.group(1), 16), m.group(3), m.group(4)))
    _RAW_CACHE[key] = seq
    return seq


def disasm_raw(path, start, length, vma):
    seq = _disasm_whole(path, vma)
    lo, hi = start, start + length
    insns = [(mn, ops) for a, mn, ops in seq if lo <= a < hi]
    return insns


def disasm_elf(path, start, length):
    out = subprocess.run(
        [OBJDUMP, '-d', '--start-address=0x%x' % start,
         '--stop-address=0x%x' % (start + length), path],
        capture_output=True, text=True).stdout
    insns = []
    for line in out.splitlines():
        m = re.match(r'\s*([0-9a-f]+):\s+([0-9a-f ]+)\t(\S+)\s*(.*)', line)
        if m:
            insns.append((m.group(3), m.group(4)))
    return insns


def our_symbols():
    out = subprocess.run([NM, '-S', '--defined-only', OURS_ELF],
                         capture_output=True, text=True).stdout
    syms = {}
    for line in out.splitlines():
        p = line.split()
        if len(p) == 4 and p[2] in 'tT':
            syms[p[3]] = (int(p[0], 16), int(p[1], 16))
    return syms


def stock_table():
    """msgid -> handler address, from command_index[]."""
    d = open(STOCK_BIN, 'rb').read()
    j = json.load(open(STOCK_DICT))
    byenc = {}
    for name, mid in j['commands'].items():
        enc = mid if mid < 0x60 else ((0x80 | (mid >> 7)) << 8) | (mid & 0x7f)
        byenc[enc] = name
    out = {}
    off = STOCK_TABLE - STOCK_BASE
    for i in range(len(j['commands'])):
        o = off + 16 * i
        enc = int.from_bytes(d[o:o+2], 'little')
        fn = int.from_bytes(d[o+12:o+16], 'little') & ~1
        if enc in byenc:
            out[byenc[enc]] = fn
    return out


def main():
    d = open(STOCK_BIN, 'rb').read()
    stock_end = STOCK_BASE + len(d)
    handlers = stock_table()
    syms = our_symbols()
    ours_cmds = set(json.load(open(OURS_DICT))['commands'])

    # sorted handler addresses, to bound each stock function
    addrs = sorted(set(handlers.values()))

    same = diff = missing = 0
    rows = []
    for name in sorted(handlers):
        if name not in ours_cmds:
            continue
        short = name.split()[0]
        sym = 'command_' + short
        cand = [s for s in syms if s == sym or s.startswith(sym + '.')]
        if not cand:
            missing += 1
            rows.append(('NOSYM', short, '', ''))
            continue
        oaddr, olen = syms[cand[0]]
        saddr = handlers[name]
        nxt = next((a for a in addrs if a > saddr), stock_end)
        slen = min(max(nxt - saddr, 0x400), olen + 64)
        s = [norm(i) for i in disasm_raw(STOCK_BIN, saddr, slen, STOCK_BASE)]
        o = [norm(i) for i in disasm_elf(OURS_ELF, oaddr, olen)]
        # nm's size covers the literal pool too; code ends at the first .word
        cut = next((k for k, x in enumerate(o) if x.startswith('.word')), len(o))
        o = o[:cut]
        s = s[:len(o)]
        if s == o:
            same += 1
            rows.append(('SAME', short, '%d insn' % len(o), ''))
        else:
            diff += 1
            first = next((k for k in range(min(len(s), len(o)))
                          if s[k] != o[k]), min(len(s), len(o)))
            rows.append(('DIFF', short, 'ours %d / stock %d insn'
                         % (len(o), len(s)), 'first diff @%d' % first))
    for r in rows:
        print("  %-6s %-28s %-24s %s" % r)
    print("\nSAME %d   DIFF %d   NOSYM %d" % (same, diff, missing))


if __name__ == '__main__':
    main()
