#!/usr/bin/env python3
"""Search source variants for one that compiles to the stock instructions.

Register allocation and scheduling differences cannot be argued into place:
the compiler is pinned, so where our code still differs the *source* must
differ.  This tries a list of semantically equivalent formulations of one
function, rebuilds each, and reports which (if any) reproduces stock's
instruction stream -- the standard technique in matching decompilation.

    permute.py <handler-name> <file> <variants.py>

<variants.py> must define ORIGINAL (the exact current text) and VARIANTS
(a list of replacement strings).
"""
import importlib.util
import subprocess
import sys

T = '/home/oleksandr/.claude/jobs/885c1997/tmp'
SRC = T + '/verify/klipper/src/'


def load(path):
    spec = importlib.util.spec_from_file_location('variants', path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m.ORIGINAL, m.VARIANTS


def build():
    return subprocess.run(['bash', T + '/setnolto.sh'],
                          capture_output=True, text=True).returncode == 0


def check(handler):
    """Return (matched, description) for one handler.

    The description carries the matching-prefix length, which is what makes
    the search steerable: a variant that agrees for 9 instructions before
    diverging is closer than one that diverges at 0, even though neither
    matches.
    """
    out = subprocess.run(['python3', T + '/cmpfuncs.py'],
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1] == handler:
            return parts[0] == 'SAME', line.strip()
    return False, '(not found)'


def main():
    handler, path, vpath = sys.argv[1], SRC + sys.argv[2], sys.argv[3]
    original, variants = load(vpath)
    text = open(path).read()
    if original not in text:
        print("ORIGINAL not present in %s" % path)
        return 1
    try:
        for i, v in enumerate(variants):
            open(path, 'w').write(text.replace(original, v, 1))
            if not build():
                print("variant %d: BUILD FAILED" % i)
                continue
            same, line = check(handler)
            print("variant %d: %s%s" % (i, 'MATCH  ' if same else '       ', line))
            if same:
                print("\nkeeping variant %d" % i)
                return 0
    finally:
        pass
    open(path, 'w').write(text)          # nothing matched; restore
    build()
    print("\nno variant matched; source restored")
    return 1


sys.exit(main())
