#!/usr/bin/env python3
"""Locate Klipper's command_index[] in a raw MCU image and map every command
in the embedded data dictionary to its handler address.

    struct command_parser {          // 16 bytes, 4-aligned
        uint16_t encoded_msgid;      // +0   VLQ-encoded msgid
        uint8_t num_args, flags;     // +2 +3
        uint8_t num_params;          // +4   (+5..7 padding)
        const uint8_t *param_types;  // +8
        void (*func)(uint32_t *);    // +12  thumb pointer (bit0 set)
    };

Usage: klip_cmdtab.py <image.bin> <image.dict.json> <load-addr>
"""
import sys, json, struct

PT = ['uint32', 'int32', 'uint16', 'int16', 'byte',
      'string', 'progmem_buffer', 'buffer']


def vlq(msgid):
    """Klipper's encoded_msgid: VLQ bytes packed into a uint16."""
    if msgid < 0x60:
        return msgid
    return ((0x80 | ((msgid >> 7) & 0x7f)) << 8) | (msgid & 0x7f)


def scan(d, base, wanted):
    end = base + len(d)
    inflash = lambda a: base <= a < end
    u32 = lambda o: struct.unpack_from('<I', d, o)[0]
    u16 = lambda o: struct.unpack_from('<H', d, o)[0]
    entries = []
    for off in range(0, len(d) - 16, 4):
        mid, na, fl, np = u16(off), d[off+2], d[off+3], d[off+4]
        pt, fn = u32(off+8), u32(off+12)
        if (mid in wanted and fn & 1 and inflash(fn & ~1) and (inflash(pt) or (pt == 0 and np == 0))
                and na <= 16 and np <= 16 and d[off+5:off+8] == b'\0\0\0'):
            entries.append((off, mid, na, fl, np, pt, fn & ~1))
    # keep the longest run of consecutive 16-byte entries
    runs, cur = [], []
    for e in entries:
        if cur and e[0] - cur[-1][0] != 16:
            runs.append(cur); cur = []
        cur.append(e)
    if cur:
        runs.append(cur)
    return max(runs, key=len) if runs else []


def main():
    img, dct, base = sys.argv[1], sys.argv[2], int(sys.argv[3], 0)
    d = open(img, 'rb').read()
    j = json.load(open(dct))
    byenc = {vlq(v): (k, v) for k, v in j['commands'].items()}
    run = scan(d, base, set(byenc))
    if not run:
        print("no command_index found"); return 1
    print("command_index[] at 0x%08X -- %d of %d commands resolved\n"
          % (base + run[0][0], len(run), len(byenc)))
    for off, mid, na, fl, np, pt, fn in run:
        name, msgid = byenc[mid]
        types = [PT[t] if t < len(PT) else '?%d' % t
                 for t in d[pt - base:pt - base + np]]
        print("  msgid=%-3d func=0x%08X flags=0x%02x  %s"
              % (msgid, fn, fl, name.split()[0]))
        print("      %s" % name)
        if types:
            print("      params: %s" % ', '.join(types))
    return 0


sys.exit(main())
