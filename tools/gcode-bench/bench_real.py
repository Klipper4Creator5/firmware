#!/usr/bin/env python3
"""Time klipper's real handling of EXCLUDE_OBJECT lines taken from a gcode file."""
import argparse, cProfile, io, os, pstats, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_define import build

def timeit(fn, repeat):
    best = None
    for _ in range(repeat):
        t0 = time.perf_counter(); fn(); dt = time.perf_counter() - t0
        best = dt if best is None else min(best, dt)
    return best

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--klipper', required=True)
    p.add_argument('--gcode', required=True)
    p.add_argument('--repeat', type=int, default=5)
    p.add_argument('--profile', action='store_true')
    a = p.parse_args()

    defines, starts = [], []
    with open(a.gcode, 'r', errors='replace') as f:
        for line in f:
            if line.startswith('EXCLUDE_OBJECT_DEFINE'):
                defines.append(line.rstrip('\n'))
            elif line.startswith(('EXCLUDE_OBJECT_START', 'EXCLUDE_OBJECT_END')):
                starts.append(line.rstrip('\n'))
    print('%s: %d DEFINE (%d bytes), %d START/END (%d bytes)'
          % (os.path.basename(a.gcode), len(defines), sum(map(len, defines)),
             len(starts), sum(map(len, starts))))
    for d in defines:
        pts = d.count('],[') + 1 if 'POLYGON' in d else 0
        print('  DEFINE %d bytes, %d polygon points' % (len(d), pts))

    def run_defines():
        gc, eo = build(a.klipper)
        gc._process_commands(list(defines), need_ack=False)
    def run_starts():
        gc, eo = build(a.klipper)
        gc._process_commands(list(starts), need_ack=False)
    def run_setup():
        build(a.klipper)

    setup = timeit(run_setup, a.repeat)
    td = timeit(run_defines, a.repeat) - setup
    ts = timeit(run_starts, a.repeat) - setup
    print('DEFINE block   : %8.1f ms' % (td * 1e3))
    print('all START/END  : %8.1f ms  (%.3f ms each)'
          % (ts * 1e3, ts * 1e3 / max(len(starts), 1)))

    if a.profile:
        gc, eo = build(a.klipper)
        pr = cProfile.Profile(); pr.enable()
        gc._process_commands(list(defines), need_ack=False)
        pr.disable()
        s = io.StringIO()
        pstats.Stats(pr, stream=s).sort_stats('tottime').print_stats(10)
        print(s.getvalue())

main()
