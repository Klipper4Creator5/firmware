#!/usr/bin/env python3
# Generate a synthetic EXCLUDE_OBJECT_DEFINE block of the shape a slicer emits.
import argparse, json, math, sys

def polygon(cx, cy, r, n):
    return [[round(cx + r * math.cos(2*math.pi*i/n), 3),
             round(cy + r * math.sin(2*math.pi*i/n), 3)] for i in range(n)]

def block(nobj, npoints, name_len=24):
    out = []
    for i in range(nobj):
        cx, cy = 20.0 + (i % 10) * 20.0, 20.0 + (i // 10) * 20.0
        name = ("PART_%d_" % i).ljust(name_len, 'X')[:max(name_len, 8)]
        poly = json.dumps(polygon(cx, cy, 8.0, npoints), separators=(',', ' '))
        out.append('EXCLUDE_OBJECT_DEFINE NAME=%s CENTER=%g,%g POLYGON=%s'
                   % (name, cx, cy, poly))
    return out

if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--objects', type=int, default=25)
    p.add_argument('--points', type=int, default=64)
    a = p.parse_args()
    sys.stdout.write('\n'.join(block(a.objects, a.points)) + '\n')
