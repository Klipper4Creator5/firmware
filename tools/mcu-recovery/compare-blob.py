#!/usr/bin/env python3
"""Compare the compressed identify blob we build against the stock image's.

Klipper stores its data dictionary deflated in flash.  Matching it is a
harder gate than matching the dictionary itself: it needs identical JSON
(so identical message ids, version stamp and toolchain string) *and*
identical deflate output, which means classic zlib rather than zlib-ng.

    compare-blob.py <out-dir> <stock.bin>
"""
import re
import sys
import zlib


def stock_blob(path):
    """The deflate stream Klipper embedded, found by scanning for it."""
    img = open(path, 'rb').read()
    for i in range(len(img) - 2):
        if img[i] != 0x78 or img[i+1] not in (0x01, 0x9c, 0xda, 0x5e):
            continue
        d = zlib.decompressobj()
        try:
            out = d.decompress(img[i:])
        except zlib.error:
            continue
        if len(out) > 200:
            return img[i:len(img) - len(d.unused_data)]
    return None


def main():
    out_dir, stock_path = sys.argv[1], sys.argv[2]
    src = open(out_dir + '/compile_time_request.c').read()
    m = re.search(r'command_identify_data\[\]\s*(?:PROGMEM\s*)?=\s*\{(.*?)\};',
                  src, re.S)
    if not m:
        print("could not find command_identify_data[]")
        return 1
    mine = bytes(int(x, 0) for x in re.findall(r'0x[0-9a-fA-F]+|\d+',
                                               m.group(1)))
    stock = stock_blob(stock_path)
    if stock is None:
        print("no deflate stream found in %s" % stock_path)
        return 1

    print("identify blob: %d bytes built, %d bytes stock" % (len(mine),
                                                             len(stock)))
    if mine == stock:
        print("compressed identify blob matches the stock firmware")
        return 0
    n = sum(1 for i in range(min(len(mine), len(stock)))
            if mine[i] != stock[i])
    print("   %d bytes differ" % n)
    try:
        same = zlib.decompress(mine) == zlib.decompress(stock)
        print("   decompressed content equal: %s" % same)
        if same:
            print("   -> same dictionary, different deflate."
                  " Set KLIPPER_ZLIB to a classic libz.")
    except zlib.error:
        pass
    return 1


sys.exit(main())
