#!/usr/bin/env python3
"""Measure klipper's gcode dispatch throughput on the move lines of a real file.

Only the parse+dispatch half runs: the handlers are no-ops, so the number is a
floor on what klippy must spend per line before any kinematics happen.
"""
import argparse, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_define import build

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--klipper', required=True)
    p.add_argument('--gcode', required=True)
    p.add_argument('--limit', type=int, default=20000)
    p.add_argument('--repeat', type=int, default=3)
    a = p.parse_args()

    moves = []
    with open(a.gcode, 'r', errors='replace') as f:
        for line in f:
            if line[:2] in ('G1', 'G0') and line[2:3] in (' ', '\n'):
                moves.append(line.rstrip('\n'))
                if len(moves) >= a.limit:
                    break

    gc, eo = build(a.klipper)
    for cmd in ('G0', 'G1', 'G92', 'M204', 'M106', 'M107'):
        gc.register_command(cmd, lambda gcmd: None)
    gc.gcode_handlers = gc.ready_gcode_handlers

    best = None
    for _ in range(a.repeat):
        t0 = time.perf_counter()
        gc._process_commands(moves, need_ack=False)
        dt = time.perf_counter() - t0
        best = dt if best is None else min(best, dt)
    print('move lines: %d' % len(moves))
    print('parse+dispatch: %.3f s total, %.3f ms/line, %.0f lines/s'
          % (best, best * 1e3 / len(moves), len(moves) / best))

main()
