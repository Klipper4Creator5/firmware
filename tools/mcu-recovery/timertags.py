#!/usr/bin/env python3
"""Recover FlashForge's per-call-site tag passed to sched_add_timer().

Stock sched_add_timer is at 0x0800626C and takes (struct timer *, uint8_t tag).
On a "timer in the past" failure it latches the tag into 0x2000010C, which the
board reports as the `close` field of its telemetry message.
"""
import re
import subprocess

T = '/home/oleksandr/.claude/jobs/885c1997/tmp'
OBJDUMP = T + '/gcc-arm-none-eabi-10.3-2021.10/bin/arm-none-eabi-objdump'
BIN = '/home/oleksandr/workspace/firmware/work/stock/mcu/levelBoard.bin'
BASE = 0x08004000
ADD_TIMER = 0x0800626C

out = subprocess.run(
    [OBJDUMP, '-D', '-b', 'binary', '-m', 'arm', '-M', 'force-thumb',
     '--adjust-vma=0x%x' % BASE, BIN], capture_output=True, text=True).stdout

ins = []
for line in out.splitlines():
    m = re.match(r'\s*([0-9a-f]+):\s+([0-9a-f ]+)\t(\S+)\s+(.*)', line)
    if m:
        ins.append((int(m.group(1), 16), m.group(3),
                    re.sub(r'\s*;.*$', '', m.group(4)).strip()))

hits = []
for i, (addr, mn, ops) in enumerate(ins):
    if mn not in ('bl', 'b.w', 'b'):
        continue
    m = re.match(r'0x([0-9a-f]+)$', ops)
    if not m or int(m.group(1), 16) != ADD_TIMER:
        continue
    tag = None
    for k in range(max(0, i - 8), i):
        a2, m2, o2 = ins[k]
        if m2 in ('movs', 'mov.w', 'movw') and o2.startswith('r1, #'):
            tag = int(o2.split('#')[1], 0)
    hits.append((addr, mn, tag))

print("%-12s %-5s %s" % ("callsite", "kind", "tag"))
for a, mn, t in hits:
    print("0x%08X  %-5s %s" % (a, mn, t if t is not None else '?? (r1 set elsewhere)'))
tags = sorted(t for _, _, t in hits if t is not None)
print("\n%d call sites; tags: %s" % (len(hits), tags))
