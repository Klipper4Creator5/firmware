#!/usr/bin/env python3
"""Prototype + equivalence test for a shlex-free fast path in _get_extended_params.

shlex is only needed for shell-style quoting. When the raw parameters carry no
quote and no backslash, a plain split is identical -- and it does not cost
O(n^2) in the length of the longest token.
"""
import argparse, os, re, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_define import build

QUOTING = re.compile(r'''['"\\]''')

def fast_params(rawparams, error):
    # shlex treats # and ; as comment introducers anywhere outside a quote.
    for c in '#;':
        i = rawparams.find(c)
        if i >= 0:
            rawparams = rawparams[:i]
    try:
        return {k.upper(): v for k, v in
                (earg.split('=', 1) for earg in rawparams.split())}
    except ValueError:
        raise error("malformed")

def install(gc):
    orig = gc._get_extended_params
    def patched(gcmd):
        rawparams = gcmd.get_raw_command_parameters()
        if QUOTING.search(rawparams) is None:
            eparams = fast_params(rawparams, gc.error)
            gcmd._params.clear()
            gcmd._params.update(eparams)
            return gcmd
        return orig(gcmd)
    gc._get_extended_params = patched
    return orig

def shlex_params(gc, rawparams):
    import shlex
    s = shlex.shlex(rawparams, posix=True)
    s.whitespace_split = True
    s.commenters = '#;'
    try:
        return {k.upper(): v for k, v in (e.split('=', 1) for e in s)}
    except ValueError:
        return 'ERROR'

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--klipper', required=True)
    p.add_argument('--gcode', nargs='*', default=[])
    p.add_argument('--repeat', type=int, default=3)
    a = p.parse_args()
    gc, eo = build(a.klipper)

    # ---- equivalence over every extended command in the given files ----
    checked = skipped = 0
    bad = []
    for path in a.gcode:
        with open(path, 'r', errors='replace') as f:
            for line in f:
                line = line.strip()
                if not line or line[0] in ';#':
                    continue
                cmd = line.split(' ', 1)[0].upper()
                if gc.is_traditional_gcode(cmd) or not cmd.replace('_', 'A').isalnum():
                    continue
                raw = line[len(cmd):]
                if raw[:1].isspace():
                    raw = raw[1:]
                if QUOTING.search(raw) is not None:
                    skipped += 1
                    continue
                want = shlex_params(gc, raw)
                try:
                    got = fast_params(raw, gc.error)
                except Exception:
                    got = 'ERROR'
                checked += 1
                if got != want:
                    bad.append((line[:70], want, got))
    print('equivalence: %d extended commands checked, %d quoted (fall back to shlex), %d mismatches'
          % (checked, skipped, len(bad)))
    for b in bad[:5]:
        print('  MISMATCH %r\n    shlex=%r\n    fast =%r' % b)

    # ---- synthetic edge cases ----
    edges = ['NAME=A B=2', 'NAME=A ; trailing', 'NAME=A # hash', '  NAME=A   B=2  ',
             'NAME=A B=', 'CENTER=1,2 POLYGON=[[1,2],[3,4]]', '']
    for e in edges:
        want, got = shlex_params(gc, e), None
        try:
            got = fast_params(e, gc.error)
        except Exception:
            got = 'ERROR'
        flag = 'ok ' if got == want else 'DIFF'
        print('  %s %-34r shlex=%-38r fast=%r' % (flag, e, want, got))

    # ---- timing on the real DEFINE ----
    for path in a.gcode:
        defines = [l.rstrip('\n') for l in open(path, errors='replace')
                   if l.startswith('EXCLUDE_OBJECT_DEFINE')]
        if not defines:
            continue
        for label in ('shlex', 'fast'):
            g, _ = build(a.klipper)
            if label == 'fast':
                install(g)
            best = None
            for _ in range(a.repeat):
                t0 = time.perf_counter()
                g._process_commands(list(defines), need_ack=False)
                dt = time.perf_counter() - t0
                best = dt if best is None else min(best, dt)
            print('%s: %-5s %8.2f ms' % (os.path.basename(path), label, best * 1e3))

main()
