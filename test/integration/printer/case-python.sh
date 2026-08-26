#!/bin/sh
# Does the CPython 3.13 the BUILD produced actually run on the printer's own
# kernel, and does it have the one module FlashForge left out? Behaviour only
# -- nothing here greps a script or reads a build log.
#
# WHY THIS CASE EXISTS AT ALL, given nothing on the printer uses this
# interpreter yet. Because "ships but is not used" is exactly the state in
# which an artefact rots unnoticed. bin/patch.sh's ABI gate proves the bytes
# are the right shape for this kernel; only the kernel can prove it will load
# them, only the loader can prove the six libraries the interpreter needs are
# on this rootfs, and only sqlite itself can prove that the module which is
# the entire reason for this build actually stores anything. Every one of
# those was measured once, by hand, in a spike that has since been deleted.
# This is that measurement, kept, and run on every full suite.
#
# THE NEGATIVE CONTROL IS THE POINT. Section 5 gives FlashForge's own
# Python 3.8.2 the library path it needs to start -- so it DOES start, and
# then cannot `import sqlite3`. Without that half, "our python imports
# sqlite3" is a fact about python in general rather than about this printer,
# and the reader has no way to tell whether anything was gained. It is also
# the fact that pins MOONRAKER_VERSION in versions.env to a 2023 commit, so it
# is worth re-establishing rather than trusting.
#
# The interpreter's prefix is COMPILED IN, so like s6 it can only be unpacked
# where it was configured to live: /usr/data/anvil, the mod prefix root.
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }
note(){ echo "  ..    $*"; }

MODDIR=/usr/data/anvil
PY=$MODDIR/bin/python3.13
# FlashForge's, the one everything still runs on. Named absolutely because
# that is how anvil-env.sh names it and section 5 is about that exact binary.
FFPY=/usr/prog/Python-3.8.2/bin/python3
FFLIBS=/usr/prog/Python-3.8.2/lib:/usr/prog/openssl-1.0.2d/lib

mkdir -p $MODDIR
gzip -dc /mnt/py.tgz | tar -x -C $MODDIR || { bad "cannot unpack py.tgz"; exit 1; }
chmod +x $MODDIR/bin/python3.13 2>/dev/null

echo "=== 0. does the interpreter load on this box at all? ==="
# The kernel check, and it is a real one: this rootfs refuses anything that is
# not little-endian NAN2008 o32 mips32r2, and says only "cannot execute binary
# file" when it does. Everything below is meaningless if this line fails.
#
# Run with an EMPTY LD_LIBRARY_PATH on purpose. FlashForge's interpreter
# cannot start without /usr/prog on the path (section 5 proves it); ours is
# linked against seven static libraries and the six glibc sonames this rootfs
# already carries, so it must start with nothing set at all. That property is
# what makes it safe to drop into a boot script later.
ver=`LD_LIBRARY_PATH= $PY -c 'import sys; print(sys.version.split()[0])' 2>&1`
case "$ver" in
    3.13.*) ok "$PY runs: $ver" ;;
    *)      bad "interpreter did not run: $ver"; exit 1 ;;
esac
note "sys.prefix: `LD_LIBRARY_PATH= $PY -c 'import sys; print(sys.prefix)' 2>&1`"
note "stdlib    : `LD_LIBRARY_PATH= $PY -c 'import sysconfig; print(sysconfig.get_paths()["stdlib"])' 2>&1`"

echo
echo "=== 1. sqlite3 STORES AND RETURNS DATA (an import proves nothing) ==="
# `import sqlite3` only proves the .so loaded. The module is a thin wrapper
# over a STATIC libsqlite3.a here, and the way a static sqlite goes wrong is
# not an ImportError -- it is a link that resolved far enough to import and
# then fails at the first call that needs libm (see the -lm comment in
# bin/patch.sh). So: make a database on the real filesystem, write to it,
# close it, reopen it from disk in a SECOND process, and read the rows back.
# A file that survives the interpreter exiting is the only proof that this is
# a database rather than a module that imports.
rm -f /tmp/probe.db
LD_LIBRARY_PATH= $PY - <<'EOP' > /tmp/sqlite1.out 2>&1
import sqlite3
db = sqlite3.connect("/tmp/probe.db")
db.execute("create table t (id integer primary key, name text, qty real)")
db.executemany("insert into t (name, qty) values (?, ?)",
               [("nozzle", 0.4), ("bed", 220.0), ("chamber", 60.5)])
db.commit()
# round() is sqlite's own, not Python's: it goes through the C library's
# floating point, which is the half of a static libsqlite3 that fails when
# libm was not on the link line.
rows = db.execute("select name, round(qty * 2, 2) from t order by id").fetchall()
db.close()
print("sqlite3", sqlite3.sqlite_version)
print("wrote", rows)
EOP
if grep -q '^sqlite3 3\.' /tmp/sqlite1.out; then
    ok "sqlite3 `sed -n 's/^sqlite3 //p' /tmp/sqlite1.out` created a table and inserted 3 rows"
    note "`grep '^wrote' /tmp/sqlite1.out`"
else
    bad "sqlite3 write failed:"
    sed 's/^/        /' /tmp/sqlite1.out
fi

# A SEPARATE process, so nothing is being read out of a cache that a single
# interpreter happened to keep in memory.
LD_LIBRARY_PATH= $PY - <<'EOP' > /tmp/sqlite2.out 2>&1
import sqlite3
db = sqlite3.connect("/tmp/probe.db")
rows = db.execute("select name, qty from t order by id").fetchall()
db.close()
assert rows == [("nozzle", 0.4), ("bed", 220.0), ("chamber", 60.5)], rows
print("reopened", len(rows))
EOP
if grep -q '^reopened 3' /tmp/sqlite2.out; then
    ok "a second process reopened /tmp/probe.db from disk and read the 3 rows back"
    note "on-disk size: `wc -c < /tmp/probe.db` bytes"
else
    bad "reopening the database failed:"
    sed 's/^/        /' /tmp/sqlite2.out
fi

echo
echo "=== 2. the other modules that needed a library nobody could borrow ==="
# Each of these is an extension module linked against one of the seven static
# libraries the build cross-compiles. They are checked one at a time and by
# name, because "import them all in one line" turns seven answers into one:
# the first failure hides the rest, and which one failed is the whole
# diagnostic -- it names the library whose build went wrong.
for m in ssl ctypes zlib lzma bz2 hashlib asyncio; do
    out=`LD_LIBRARY_PATH= $PY -c "import $m" 2>&1`
    if [ -z "$out" ]; then
        ok "import $m"
    else
        bad "import $m -> `echo \"$out\" | tail -1`"
    fi
done
note "openssl: `LD_LIBRARY_PATH= $PY -c 'import ssl; print(ssl.OPENSSL_VERSION)' 2>&1`"
# NOT a failure, and deliberately not silent: the build points OpenSSL's
# openssldir at $MODDIR/ssl and nothing installs a CA bundle there.
# TLS works; VERIFYING a certificate chain does not, until someone ships one.
# Anything that fetches over https on this interpreter has to be handed a
# cafile of its own. See tools/python/README.md.
note "CA store: `LD_LIBRARY_PATH= $PY -c 'import ssl; p=ssl.get_default_verify_paths(); print(p.openssl_cafile, p.openssl_capath)' 2>&1`"
LD_LIBRARY_PATH= $PY -c 'import ssl,os,sys; p=ssl.get_default_verify_paths(); sys.exit(0 if (p.openssl_cafile and os.path.exists(p.openssl_cafile)) or (p.openssl_capath and os.path.isdir(p.openssl_capath)) else 1)' 2>/dev/null \
    && note "a CA store EXISTS -- someone shipped one; certificate verification now works" \
    || note "no CA store on this printer (expected): ssl.create_default_context() cannot verify a chain"

echo
echo "=== 3. nothing under /usr/prog is mapped ==="
# The whole design of this build -- seven static libraries, --disable-shared,
# its own prefix -- exists so that this interpreter shares NOTHING with
# FlashForge's tree. If it quietly picked up /usr/prog/openssl-1.0.2d or
# /usr/prog/libffi-3.4.4 then it is not an independent interpreter at all, it
# is a second front-end to the same fragile set of libraries, and a stock OTA
# that replaces one of them takes it out.
#
# /proc/PID/maps is the authority here, not ldd and not readelf: what is
# asked is what a RUNNING process has actually loaded. The process maps
# itself, so it can read its own maps and print them.
LD_LIBRARY_PATH= $PY - <<'EOP' > /tmp/maps.out 2>&1
import ctypes, hashlib, lzma, sqlite3, ssl, zlib          # noqa: F401
# Import first, then look: a module whose .so has not been loaded yet cannot
# have mapped the library it links against, so a maps check that ran before
# the imports would pass vacuously.
libs = set()
with open("/proc/self/maps") as fh:
    for line in fh:
        parts = line.split()
        if len(parts) >= 6 and parts[-1].startswith("/"):
            libs.add(parts[-1])
for path in sorted(libs):
    print(path)
EOP
PROG=`grep -c '^/usr/prog' /tmp/maps.out 2>/dev/null`
if [ "${PROG:-1}" = "0" ]; then
    ok "with ssl+ctypes+sqlite3+lzma+zlib+hashlib all imported, 0 mappings under /usr/prog"
else
    bad "$PROG mappings under /usr/prog -- this interpreter is NOT independent:"
    grep '^/usr/prog' /tmp/maps.out | sed 's/^/        /'
fi
note "what it does map:"
sed 's/^/        /' /tmp/maps.out

echo
echo "=== 4. the ELF the kernel actually loaded ==="
# Cheap, and it names the runtime dependency that is easiest to lose:
# libatomic.so.1. 64-bit atomics on mips32 are out-of-line calls, so the
# interpreter has a DT_NEEDED on it -- and libatomic is the one soname of the
# six that is NOT obviously part of a base system. It is on this rootfs
# (measured); a rootfs without it would fail at section 0 with a loader error
# and no explanation, so it is worth saying out loud where it came from.
if grep -q 'libatomic' /tmp/maps.out; then
    ok "libatomic.so.1 resolved from the rootfs: `grep libatomic /tmp/maps.out | head -1`"
else
    note "libatomic not in the maps -- it is a DT_NEEDED, so section 0 would have failed"
fi

echo
echo "=== 5. THE NEGATIVE CONTROL: FlashForge's 3.8.2 cannot do this ==="
# Given the library path it needs, the stock interpreter starts. It has to, or
# the next assertion would be about a broken command line rather than about a
# missing module -- and this is the shape of the mistake that makes a negative
# control worthless.
if [ ! -x "$FFPY" ]; then
    bad "no $FFPY on this printer -- the control cannot run, and the case above proves less without it"
else
    ffver=`LD_LIBRARY_PATH=$FFLIBS $FFPY -c 'import sys; print(sys.version.split()[0])' 2>&1`
    case "$ffver" in
        3.8.*) ok "the stock interpreter starts when given its library path: $ffver" ;;
        *)     bad "stock interpreter did not start at all ($ffver) -- control invalid" ;;
    esac
    out=`LD_LIBRARY_PATH=$FFLIBS $FFPY -c 'import sqlite3' 2>&1`
    case "$out" in
        *"No module named"*sqlite3*|*ImportError*|*ModuleNotFoundError*)
            ok "and it CANNOT import sqlite3: `echo \"$out\" | tail -1`" ;;
        "")
            bad "the stock 3.8.2 imported sqlite3 -- FlashForge changed the firmware and"
            bad "  versions.env's Moonraker pin (and this whole build) should be revisited" ;;
        *)
            bad "stock sqlite3 import failed for an unexpected reason: `echo \"$out\" | tail -1`" ;;
    esac
    # And the same question asked of the module that DOES exist on both, so
    # that "cannot import sqlite3" reads as a fact about sqlite3 rather than
    # about a stock interpreter that cannot import anything in this harness.
    out=`LD_LIBRARY_PATH=$FFLIBS $FFPY -c 'import json, zlib' 2>&1`
    [ -z "$out" ] && ok "the same stock interpreter imports json and zlib fine (so the control is sound)" \
                  || bad "stock interpreter cannot import json/zlib either -- the control proves nothing: $out"
fi

echo
echo "=== 6. and FlashForge's interpreter is still the one on PATH ==="
# The interpreter ships into the SAME bin/ as s6, and anvil-env.sh prepends
# that directory to PATH -- s6-svscan execs s6-supervise by name, so it has
# to. CPython's own `make install` puts a `python3` symlink beside
# `python3.13`, and if that symlink shipped it would sit in front of
# FlashForge's on the PATH of every process that sources anvil-env.sh:
# anything saying `python3` rather than "$FF_PYTHON" would change interpreter
# without anyone deciding to. bin/patch.sh deletes it before staging; this is
# the check that the deletion happened, asked of the SHELL rather than of the
# directory listing, because what matters is what a command resolves to.
if [ -e "$MODDIR/bin/python3" ]; then
    bad "$MODDIR/bin/python3 exists -- it shadows FlashForge's interpreter"
else
    ok "no $MODDIR/bin/python3 -- only python3.13, which nothing else answers to"
fi
# The real question, with the mod's own PATH in force. `command -v` is the
# shell's answer to "what would run", which is exactly what a stray symlink
# would change.
#
# The PATH built here is the one anvil-env.sh builds, spelled out rather than
# sourced: $MODDIR/bin PREPENDED (s6 needs to find s6-supervise) and
# FlashForge's python directory APPENDED. A bare $PATH will not do -- the
# replica's login shell does not carry /usr/prog at all, so `command -v
# python3` would answer "nothing", the check would have nothing to compare
# and would pass without asking anything.
ANVILPATH=$MODDIR/bin:$PATH:/usr/prog/Python-3.8.2/bin
resolved=`PATH=$ANVILPATH command -v python3 2>/dev/null`
if [ "$resolved" = "$FFPY" ]; then
    ok "on anvil-env.sh's PATH, python3 still resolves to $resolved"
else
    bad "python3 resolves to '$resolved' -- expected FlashForge's $FFPY"
fi
# And the interpreter we DID ship is reachable by its own name on that same
# PATH, because "nothing shadows FlashForge's" would also be true of a payload
# that shipped no interpreter at all.
resolved=`PATH=$ANVILPATH command -v python3.13 2>/dev/null`
[ "$resolved" = "$PY" ] \
    && ok "and python3.13 on the same PATH is ours: $resolved" \
    || bad "python3.13 resolves to '$resolved' -- expected $PY"

echo
echo "=== 7. footprint ==="
note "on-disk: `du -sh $MODDIR/lib/python3.13 2>/dev/null | cut -f1`, `find $MODDIR/lib/python3.13 -type f | wc -l` stdlib files"
note "startup RSS (kB): `LD_LIBRARY_PATH= $PY -c 'import resource; print(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)' 2>&1`"

echo
[ $FAIL -eq 0 ] && echo "  python: all checks passed"
exit $FAIL
