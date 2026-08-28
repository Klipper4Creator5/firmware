#!/usr/bin/env python3
"""c_helper.so must export every function klippy declares to cffi.

cffi resolves symbols LAZILY: `ffi_lib.foo` is looked up the first time it is
touched, not at load. So a c_helper.so built from older sources than the klippy
tree beside it imports cleanly, passes an ABI check, installs, boots -- and
then dies at `Unhandled exception during connect` on the printer, with a
traceback that points at cffi rather than at the stale build.

That is not hypothetical: a .so built four days before kin_extruder.c gained
extruder_stepper_free shipped and bricked klippy startup on hardware. The .so
is a build artifact and is not committed, so nothing else forces it to be
rebuilt when the sources move.

    ./test/test-chelper.py <path/to/klipper>

Reads the cdef blocks out of klippy/chelper/__init__.py and checks each
declared function against the .so's dynamic symbol table.

THE PATH IS REQUIRED. It used to be optional, falling back to KLIPPER_FORK in
config.env -- and the fallback was the failure mode: an unset KLIPPER_FORK
turned this into "SKIP: no KLIPPER_FORK configured", a green line for a check
that had not run. Both callers pass a path (pkgs/klipper/build.sh over the
package it just built, bin/verify.sh over the finished one) and KLIPPER_FORK
no longer exists, so a missing argument is a caller bug and says so.
"""
import os
import re
import subprocess
import sys

# C keywords and cffi type words that can be followed by "(" without being a
# function being declared.
NOT_FUNCTIONS = set("""
if while for switch return sizeof struct union enum typedef const void char int
long short unsigned signed float double static inline extern volatile restrict
uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t size_t
""".split())


def declared_functions(init_py):
    text = open(init_py, encoding="utf-8", errors="replace").read()
    # Only the cdef blocks: every one is a triple-quoted defs_* assignment.
    blocks = re.findall(r'defs_\w+\s*=\s*"""(.*?)"""', text, re.S)
    cdefs = "\n".join(blocks)
    # Drop struct/union bodies so function-pointer members do not look like
    # declarations of their own.
    cdefs = re.sub(r"\b(?:struct|union)\s+\w*\s*\{.*?\}", " ", cdefs, flags=re.S)
    names = set()
    for m in re.finditer(r"\b([A-Za-z_]\w*)\s*\([^;{]*\)\s*;", cdefs):
        name = m.group(1)
        if name not in NOT_FUNCTIONS:
            names.add(name)
    return names


def exported_symbols(so):
    try:
        out = subprocess.run(["readelf", "--dyn-syms", "-W", so],
                             capture_output=True, text=True, check=True).stdout
    except FileNotFoundError:
        print("  SKIP: readelf not installed (binutils)")
        sys.exit(0)
    except subprocess.CalledProcessError as e:
        print("  FAIL: readelf could not read %s\n%s" % (so, e.stderr.strip()))
        sys.exit(1)
    defined, imported = set(), set()
    for line in out.splitlines():
        f = line.split()
        # Num: Value Size Type Bind Vis Ndx Name
        if len(f) >= 8 and f[3] == "FUNC":
            name = f[7].split("@")[0]
            (imported if f[6] == "UND" else defined).add(name)
    return defined, imported


def main():
    if len(sys.argv) < 2:
        print("usage: test-chelper.py <path/to/klipper>", file=sys.stderr)
        return 2
    fork = sys.argv[1]
    so = os.path.join(fork, "klippy", "chelper", "c_helper.so")
    init_py = os.path.join(fork, "klippy", "chelper", "__init__.py")
    # Still a skip rather than a failure: bin/verify.sh runs this over a
    # BUILD_KLIPPER=stock package too, where there is no fork tree to check.
    if not os.path.exists(so) or not os.path.exists(init_py):
        print("  SKIP: no c_helper.so / __init__.py under %s" % fork)
        return 0

    want = declared_functions(init_py)
    defined, imported = exported_symbols(so)
    if not want:
        print("  FAIL: parsed no declarations out of %s" % init_py)
        return 1

    # klippy also cdefs a few libc functions (free, ...). Those show up as UND
    # imports from glibc and dlsym resolves them through the .so's
    # dependencies, so an import counts as satisfied.
    missing = sorted(want - defined - imported)
    print("checking %d functions klippy declares against %s" % (len(want), so))
    if missing:
        print("  \033[31mFAIL\033[0m  %d declared function(s) not exported:"
              % len(missing))
        for n in missing:
            print("          %s" % n)
        print()
        print("  The .so is stale: it was built from older sources than the")
        print("  klippy tree next to it. cffi resolves lazily, so this does")
        print("  NOT fail at import -- it fails on the printer at connect.")
        print("  Rebuild it with the Ingenic/K1 toolchain (%s)." %
              "mips-linux-gnu-gcc, see klippy/chelper/__init__.py")
        return 1
    print("  \033[32mPASS\033[0m  all %d declared functions are exported" % len(want))
    return 0


if __name__ == "__main__":
    sys.exit(main())
