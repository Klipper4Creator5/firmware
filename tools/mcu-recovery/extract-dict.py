#!/usr/bin/env python3
"""Pull Klipper's embedded data dictionary out of a raw MCU image.

Klipper compresses the identify dictionary with zlib and stores it in
flash, so a stock image hands over its whole wire protocol -- every
command, response, config constant and enumeration -- without a single
instruction being disassembled.

    extract-dict.py <image.bin> [out.json]
"""
import json
import sys
import zlib


def find_dict(data):
    """Return the largest zlib stream in the image, or None."""
    best = None
    for i in range(len(data) - 2):
        if data[i] != 0x78 or data[i+1] not in (0x01, 0x9c, 0xda, 0x5e):
            continue
        try:
            raw = zlib.decompressobj().decompress(data[i:])
        except zlib.error:
            continue
        if len(raw) > 200 and (best is None or len(raw) > len(best[1])):
            best = (i, raw)
    return best


def main():
    img = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else None
    data = open(img, 'rb').read()
    hit = find_dict(data)
    if hit is None:
        print("no Klipper dictionary in %s" % img)
        return 1
    off, raw = hit
    j = json.loads(raw)
    cfg = j.get('config', {})
    print("%s: %d byte dictionary at file offset 0x%X" % (img, len(raw), off))
    print("  app       %s (%s)" % (j.get('app'), j.get('license')))
    print("  version   %s" % j.get('version'))
    print("  built     %s" % j.get('build_versions'))
    print("  mcu       %s @ %s Hz, %s baud"
          % (cfg.get('MCU'), cfg.get('CLOCK_FREQ'), cfg.get('SERIAL_BAUD')))
    print("  %d commands, %d responses"
          % (len(j.get('commands', {})), len(j.get('responses', {}))))
    if out:
        open(out, 'wb').write(raw)
        print("  written to %s" % out)
    return 0


sys.exit(main())
