#!/bin/sh
# Do the cross-built third-party packages actually WORK on the CPython 3.13
# this repo builds, on the printer's own kernel?
#
# SPIKE GATE for phase 6. bin/patch.sh section 5c already ships an interpreter
# nothing runs; this asks the question that stands between that interpreter
# and FF_PYTHON pointing at it: Moonraker and klippy import third-party C
# extensions, those exist on this printer only as mipsel .so files built
# against 3.8, and none had been built for 3.13.
#
# IMPORTS ARE NOT THE MEASUREMENT. A cross-built .so that is the wrong ABI
# fails at import, so an import does prove something -- but a cffi that
# imports and cannot dlopen, a greenlet that imports and segfaults the first
# time it switches stacks, and an lmdb that imports and then tries to run a
# compiler are all things that have happened here or in the notes. So each
# native package is USED: cffi opens a real library and calls a function
# through it the way klippy's chelper does, greenlet switches out and back and
# proves the ORDER, lmdb writes a database and a SECOND PROCESS reads it.
#
# THE REAL PRIZE is section 5: Moonraker's own component list, taken from its
# CORE_COMPONENTS plus the printer's moonraker.conf, imported on 3.13. That is
# the same check case-moonraker.sh section 7 runs against FlashForge's 3.8.2,
# pointed at the new interpreter.
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }
note(){ echo "  ..    $*"; }

MODDIR=/usr/data/anvil
PY=$MODDIR/bin/python3.13
SP=$MODDIR/lib/python3.13/site-packages
MRROOT=/usr/data/mrsrc

mkdir -p $MODDIR
gzip -dc /mnt/py.tgz  | tar -x -C $MODDIR || { bad "cannot unpack py.tgz"; exit 1; }
chmod +x $PY 2>/dev/null

# The extension tree lands in the interpreter's OWN site-packages, which is
# already on sys.path -- no PYTHONPATH, no .pth file, nothing for a boot
# script to get wrong.
mkdir -p $SP
gzip -dc /mnt/ext.tgz | tar -x -C /tmp || { bad "cannot unpack ext.tgz"; exit 1; }
cp -a /tmp/site-packages/. $SP/ || { bad "cannot stage site-packages"; exit 1; }

mkdir -p $MRROOT
gzip -dc /mnt/mr.tgz  | tar -x -C $MRROOT || note "no moonraker tarball"

# Empty on purpose, throughout. The interpreter is statically linked against
# its seven C libraries and every extension below was linked against the same
# toolchain, so nothing here may need a search path -- and if something does,
# that is the finding.
export LD_LIBRARY_PATH=

echo "=== 0. the interpreter still runs with the tree dropped in ==="
ver=`$PY -c 'import sys; print(sys.version.split()[0])' 2>&1`
case "$ver" in
    3.13.*) ok "$PY runs: $ver" ;;
    *)      bad "interpreter did not run: $ver"; exit 1 ;;
esac
note "site-packages: `ls $SP | wc -l` entries"

echo
echo "=== 1. every package imports ==="
# One process, one import each, so a single failure names itself instead of
# stopping the list.
$PY - <<'EOP' > /tmp/imp.out 2>&1
import importlib, sys
# libnacl is deliberately NOT here: it ctypes-loads libsodium, which lives
# only under /usr/prog on this box, and section 4 is about exactly that.
mods = ["tornado", "tornado.web", "jinja2", "markupsafe", "distro",
        "inotify_simple", "dbus_next", "preprocess_cancellation",
        "serial", "serial_asyncio", "cffi", "_cffi_backend", "greenlet",
        "lmdb", "smart_open", "streaming_form_data", "PIL", "PIL.Image",
        "setuptools",
        "pkg_resources"]
bad = 0
for m in mods:
    try:
        mod = importlib.import_module(m)
        where = getattr(mod, "__file__", "?") or "?"
        print("  ok   %-24s %s" % (m, where.replace("/usr/data/anvil", "$")))
    except BaseException as exc:
        print("  FAIL %-24s %r" % (m, exc))
        bad += 1
print("import failures: %d" % bad)
EOP
sed -n 's/^/    /p' /tmp/imp.out
grep -q '^import failures: 0' /tmp/imp.out \
    && ok "every package imports on 3.13" \
    || bad "`grep '^import failures' /tmp/imp.out`"

echo
echo "=== 2. the C extensions WORK, not merely import ==="

# ---- cffi, the way klippy uses it -----------------------------------------
# klippy's chelper does ffi.cdef() then ffi.dlopen(c_helper.so) -- ABI mode,
# no compiler. That matters here beyond convenience: there IS no compiler on
# this printer. So: declare a function, dlopen a real library, call it, and
# check the ANSWER. libm is used rather than a library of ours because it is
# on this rootfs whatever else is true.
$PY - <<'EOP' > /tmp/cffi.out 2>&1
import cffi
ffi = cffi.FFI()
ffi.cdef("double sqrt(double); double pow(double, double);")
lib = ffi.dlopen("libm.so.6")
a = lib.sqrt(1024.0)
b = lib.pow(2.0, 10.0)
buf = ffi.new("char[]", b"nozzle")
print("sqrt(1024)=%r pow(2,10)=%r buf=%r" % (a, b, ffi.string(buf)))
assert a == 32.0 and b == 1024.0 and ffi.string(buf) == b"nozzle"
print("cffi ok")
EOP
grep -q '^cffi ok' /tmp/cffi.out \
    && ok "cffi cdef+dlopen+call through libm: `head -1 /tmp/cffi.out`" \
    || bad "cffi: `tail -3 /tmp/cffi.out`"

# ---- greenlet, the way klippy's reactor uses it ----------------------------
# The one that was expected to fight. An import proves the .so loaded; only a
# switch proves the hand-written MIPS stack-switching assembly in
# switch_mips_unix.h does what it says. So switch out, switch back, switch out
# again, and check the ORDER -- a stack switch that half-works produces a
# plausible-looking result in the wrong sequence.
$PY - <<'EOP' > /tmp/gl.out 2>&1
import greenlet
seq = []
def child():
    seq.append("child-1")
    value = main.switch("up")
    seq.append("child-2:%s" % value)
    return "done"
main = greenlet.getcurrent()
g = greenlet.greenlet(child)
seq.append("main-1")
got = g.switch()
seq.append("main-2:%s" % got)
result = g.switch("down")
seq.append("main-3:%s" % result)
print("|".join(seq))
assert seq == ["main-1", "child-1", "main-2:up", "child-2:down", "main-3:done"], seq
assert g.dead
print("greenlet ok")
EOP
grep -q '^greenlet ok' /tmp/gl.out \
    && ok "greenlet switches and returns in order: `head -1 /tmp/gl.out`" \
    || bad "greenlet: `tail -5 /tmp/gl.out`"

# ---- lmdb, and the trap it is famous for here ------------------------------
# phase 6's notes record a trimmed tree in which the lmdb egg fell back to its
# CFFI backend and tried to invoke mips-linux-gnu-gcc ON THE PRINTER at
# Moonraker startup. So this asserts WHICH backend loaded before it asserts
# that the database works.
$PY - <<'EOP' > /tmp/lmdb1.out 2>&1
import lmdb, os, shutil
print("backend:", lmdb.__file__)
import lmdb.cpython
print("cpython backend loaded:", lmdb.cpython.__file__)
shutil.rmtree("/tmp/lm", ignore_errors=True)
os.makedirs("/tmp/lm")
env = lmdb.open("/tmp/lm", map_size=1 << 20)
with env.begin(write=True) as txn:
    txn.put(b"nozzle", b"0.4")
    txn.put(b"bed", b"220")
env.close()
print("wrote")
EOP
sed -n 's/^/    /p' /tmp/lmdb1.out
if grep -q 'cpython backend loaded' /tmp/lmdb1.out; then
    ok "lmdb loaded its CPython extension, not the compile-at-import cffi path"
else
    bad "lmdb backend: `tail -3 /tmp/lmdb1.out`"
fi
# A SECOND PROCESS, because a database that only exists inside the writer is
# not a database.
$PY - <<'EOP' > /tmp/lmdb2.out 2>&1
import lmdb
env = lmdb.open("/tmp/lm", readonly=True)
with env.begin() as txn:
    print("read back: nozzle=%s bed=%s" % (txn.get(b"nozzle"), txn.get(b"bed")))
    assert txn.get(b"nozzle") == b"0.4" and txn.get(b"bed") == b"220"
print("lmdb ok")
EOP
grep -q '^lmdb ok' /tmp/lmdb2.out \
    && ok "lmdb round-trips through a second process: `head -1 /tmp/lmdb2.out`" \
    || bad "lmdb: `tail -3 /tmp/lmdb2.out`"

# ---- the two optional accelerators, and streaming-form-data ---------------
$PY - <<'EOP' > /tmp/spd.out 2>&1
import markupsafe, tornado.escape
print("markupsafe accel:", markupsafe.escape.__module__)
print("escape:", str(markupsafe.escape("<a href='x'>&")))
assert str(markupsafe.escape("<a>")) == "&lt;a&gt;"
try:
    from tornado import speedups
    print("tornado speedups:", speedups.__file__)
except ImportError as exc:
    print("tornado speedups absent (pure fallback):", exc)
# The five names moonraker asks of streaming_form_data, and a real parse.
from streaming_form_data import StreamingFormDataParser
from streaming_form_data.targets import FileTarget, ValueTarget, SHA256Target
from streaming_form_data.validators import ValidationError
body = (b"--BOUND\r\nContent-Disposition: form-data; name=\"print\"\r\n\r\n"
        b"benchy.gcode\r\n--BOUND--\r\n")
target = ValueTarget()
p = StreamingFormDataParser(headers={"Content-Type": "multipart/form-data; boundary=BOUND"})
p.register("print", target)
p.data_received(body)
print("parsed:", target.value)
assert target.value == b"benchy.gcode"
print("speedups ok")
EOP
sed -n 's/^/    /p' /tmp/spd.out
grep -q '^speedups ok' /tmp/spd.out \
    && ok "markupsafe accelerator and streaming-form-data parse real input" \
    || bad "accelerators: `tail -4 /tmp/spd.out`"

# ---- pillow, on the one path moonraker actually uses it for ---------------
# Not "import PIL". Moonraker's metadata subprocess pulls a base64 PNG
# thumbnail out of a gcode comment, decodes it, resizes it and writes it back
# out -- so this does exactly that, through a Pillow built with zlib and NO
# other codec. If the zlib link were wrong, the import would still succeed and
# the save would fail.
$PY - <<'EOP' > /tmp/pil.out 2>&1
import base64, io
from PIL import Image, features
print("zlib codec:", features.check("zlib"))
img = Image.new("RGBA", (64, 48), (200, 30, 30, 255))
for x in range(0, 64, 8):
    for y in range(0, 48, 8):
        img.putpixel((x, y), (10, 10, 240, 255))
raw = io.BytesIO()
img.save(raw, format="PNG")
encoded = base64.b64encode(raw.getvalue())
print("encoded png: %d bytes base64" % len(encoded))
back = Image.open(io.BytesIO(base64.b64decode(encoded)))
back.load()
small = back.resize((32, 32))
out = io.BytesIO()
small.save(out, format="PNG")
print("decoded %s %s -> resized %s, %d bytes"
      % (back.format, back.size, small.size, len(out.getvalue())))
assert back.size == (64, 48) and back.getpixel((0, 0)) == (10, 10, 240, 255)
assert small.size == (32, 32) and len(out.getvalue()) > 0
print("pillow ok")
EOP
sed -n 's/^/    /p' /tmp/pil.out
grep -q '^pillow ok' /tmp/pil.out \
    && ok "pillow decodes, resizes and re-encodes a PNG thumbnail" \
    || bad "pillow: `tail -4 /tmp/pil.out`"

# ---- cffi against klippy's REAL c_helper.so -------------------------------
# The question phase 7 turns on, asked here because the answer is cheap: can
# 3.13's cffi bind the printer's own klippy helper? c_helper.so is a plain
# glibc shared object dlopen'd in ABI mode, so it should not care which python
# opened it -- "should not care" being exactly the kind of claim worth
# measuring on the box rather than asserting in a report.
CH=`find /usr/prog -name 'c_helper*.so' 2>/dev/null | head -1`
if [ -n "$CH" ]; then
    note "found $CH"
    $PY - "$CH" <<'EOP' > /tmp/chelper.out 2>&1
import sys, cffi
ffi = cffi.FFI()
# A handful of klippy's own declarations, spelled the way chelper does.
ffi.cdef("""
    struct stepcompress *stepcompress_alloc(uint32_t oid);
    struct steppersync *steppersync_alloc(struct serialqueue *sq
        , struct stepcompress **sc_list, int sc_num, int move_num);
    double itersolve_generate_steps(struct stepper_kinematics *sk, double flush_time);
""")
lib = ffi.dlopen(sys.argv[1])
found = []
for name in ("stepcompress_alloc", "steppersync_alloc",
             "itersolve_generate_steps"):
    try:
        getattr(lib, name)          # cffi resolves lazily: this is the dlsym
        found.append(name)
    except Exception as exc:
        print("  %s: %r" % (name, exc))
print("resolved: %s" % " ".join(found))
sc = lib.stepcompress_alloc(0)
print("stepcompress_alloc(0) ->", "non-NULL" if sc else "NULL")
assert len(found) == 3 and sc
print("chelper ok")
EOP
    sed -n 's/^/    /p' /tmp/chelper.out
    grep -q '^chelper ok' /tmp/chelper.out \
        && ok "3.13's cffi dlopens the printer's own c_helper.so and calls into it" \
        || bad "c_helper.so through 3.13 cffi: `tail -4 /tmp/chelper.out`"
else
    note "no c_helper.so on this image -- klippy binding not measured here"
fi

echo
echo "=== 3. nothing maps a library under /usr/prog ==="
# The property the whole static-linking decision exists to buy, re-established
# with the extension tree in place: /usr/prog carries libffi.so.8 against the
# rootfs's .so.7, an openssl 1.0.2d, and a stock OTA can replace any of it.
# The process below has imported every native module first, so any mapping
# would already be in /proc/self/maps.
$PY - <<'EOP' > /tmp/maps.out 2>&1
import ssl, ctypes, sqlite3, lzma, zlib, hashlib          # the interpreter's
import cffi, _cffi_backend, greenlet, lmdb, markupsafe    # ours
import streaming_form_data, tornado.web, jinja2
from PIL import Image
libs = [l.split()[-1] for l in open("/proc/self/maps")
        if ".so" in l and l.split()[-1].startswith("/")]
prog = sorted(set(l for l in libs if l.startswith("/usr/prog")))
print("mapped libraries: %d" % len(set(libs)))
for l in sorted(set(libs)):
    print("   %s" % l)
print("under /usr/prog: %d" % len(prog))
EOP
sed -n 's/^/    /p' /tmp/maps.out
grep -q '^under /usr/prog: 0' /tmp/maps.out \
    && ok "no library under /usr/prog is mapped, with every extension imported" \
    || bad "`grep '^under /usr/prog' /tmp/maps.out`"

echo
echo "=== 4. libnacl, and the one dependency that is NOT solved ==="
# libnacl is pure python -- it ctypes-loads libsodium, which this rootfs does
# not have and /usr/prog does. Nothing was cross-built to fix that, so this
# reports the state rather than asserting one, exactly as case-python.sh does
# for the missing CA bundle.
$PY - <<'EOP' > /tmp/nacl.out 2>&1
import ctypes.util, os
print("ctypes.util.find_library('sodium') ->", ctypes.util.find_library("sodium"))
for p in ("/usr/lib/libsodium.so", "/lib/libsodium.so",
          "/usr/prog/libsodium/lib/libsodium.so"):
    print("  %-42s %s" % (p, "present" if os.path.exists(p) else "-"))
try:
    import libnacl
    print("libnacl imported, sodium at:", libnacl.nacl._name)
except BaseException as exc:
    print("libnacl NOT importable: %r" % (exc,))
EOP
sed -n 's/^/    /p' /tmp/nacl.out
if grep -q 'libnacl imported' /tmp/nacl.out; then
    note "libnacl found libsodium without help"
else
    note "libnacl needs libsodium and this rootfs has it ONLY under /usr/prog"
fi
# With /usr/prog on the path, the way anvil-env.sh puts it there today.
LD_LIBRARY_PATH=/usr/prog/libsodium/lib $PY -c \
    'import libnacl; print("libnacl ok:", libnacl.nacl._name)' \
    > /tmp/nacl2.out 2>&1
if grep -q '^libnacl ok' /tmp/nacl2.out; then
    ok "libnacl works when /usr/prog/libsodium is on the path: `cat /tmp/nacl2.out`"
else
    bad "libnacl even with libsodium on the path: `tail -3 /tmp/nacl2.out`"
fi

echo
echo "=== 5. THE PRIZE: Moonraker's own component list, on 3.13 ==="
# Lifted from case-moonraker.sh section 7 and pointed at the new interpreter.
# The component list is NOT written down here: it comes from Moonraker's own
# CORE_COMPONENTS plus every section in the printer's moonraker.conf, which is
# what keeps this honest when the pin moves or somebody configures a component
# nobody thought about.
CONF=/usr/data/config/moonraker.conf
if [ ! -f "$CONF" ]; then
    # No installed config in this run -- use the one the mod ships.
    mkdir -p /usr/data/config
    cat > "$CONF" <<'CFG'
[server]
[machine]
[file_manager]
[authorization]
[history]
[webcam anvil]
CFG
    note "no installed moonraker.conf; using the mod's own section set"
fi
if [ -d "$MRROOT/moonraker" ]; then
    LD_LIBRARY_PATH=/usr/prog/libsodium/lib $PY - "$MRROOT" "$CONF" <<'PY' > /tmp/mr.out 2>&1
import glob, importlib, os, re, sys
sys.path.insert(0, sys.argv[1])
try:
    import moonraker.server as server
except Exception as exc:
    print("moonraker.server does not import: %r" % (exc,))
    raise SystemExit(2)

names = list(getattr(server, "CORE_COMPONENTS", []))

def scan(path, depth=0):
    try:
        lines = open(path).readlines()
    except OSError:
        return
    for line in lines:
        section = re.match(r"\s*\[\s*([A-Za-z0-9_]+)", line)
        if not section:
            continue
        if section.group(1) == "include":
            inc = re.match(r"\s*\[\s*include\s+([^\]]+?)\s*\]", line)
            if inc and depth < 3:
                base = os.path.dirname(os.path.abspath(path))
                for f in sorted(glob.glob(os.path.join(base, inc.group(1)))):
                    scan(f, depth + 1)
            continue
        names.append(section.group(1))

scan(sys.argv[2])

failures = []
checked = []
for name in dict.fromkeys(names):
    target = "moonraker.components." + name
    try:
        importlib.import_module(target)
        checked.append(name)
    except ModuleNotFoundError as exc:
        # A section that is not a component at all ([server]) is fine. A
        # missing DEPENDENCY of a component that does exist is the point.
        if getattr(exc, "name", None) == target:
            continue
        failures.append((name, repr(exc)))
    except Exception as exc:
        failures.append((name, repr(exc)))

print("imported: %s" % " ".join(sorted(checked)))
for name, err in failures:
    print("  %s: %s" % (name, err))
print("components ok: %d" % len(checked) if not failures
      else "%d component(s) will not load" % len(failures))
raise SystemExit(1 if failures else 0)
PY
    sed -n 's/^/    /p' /tmp/mr.out
    if grep -q '^components ok:' /tmp/mr.out; then
        ok "`grep '^components ok:' /tmp/mr.out` on CPython 3.13"
    else
        bad "components will not load: `tail -5 /tmp/mr.out`"
    fi

    echo
    echo "--- 5b. moonraker's own entry point, and its server object ---"
    # Importing components proves the dependencies are there. Building the
    # Server is what proves the 3.13 stdlib underneath them still fits: this
    # pin is a 2023 tree and asyncio, importlib and inspect have all moved.
    LD_LIBRARY_PATH=/usr/prog/libsodium/lib $PY - "$MRROOT" <<'PY' > /tmp/mr2.out 2>&1
import sys
sys.path.insert(0, sys.argv[1])
import moonraker.moonraker as entry
import moonraker.server, moonraker.confighelper, moonraker.common
import moonraker.eventloop, moonraker.loghelper, moonraker.utils
import moonraker.utils.json_wrapper as jw
print("entry:", entry.__file__)
print("json backend:", "msgspec" if jw.MSGSPEC_ENABLED else "stdlib json")
print("round trip:", jw.loads(jw.dumps({"state": "ready", "z": 0.4})))
print("moonraker ok")
PY
    sed -n 's/^/    /p' /tmp/mr2.out
    grep -q '^moonraker ok' /tmp/mr2.out \
        && ok "moonraker's entry point and core modules import on 3.13" \
        || bad "moonraker entry: `tail -5 /tmp/mr2.out`"
else
    note "no moonraker tree at $MRROOT -- pass mr.tgz=..."
fi

echo
echo "=== 6. NEGATIVE CONTROL: take the tree away ==="
# Without this half, "the components import" is a fact about python in
# general. Move the cross-built site-packages aside and the SAME check must
# fail -- otherwise something else on this box is satisfying the imports and
# the tree is not what is being measured.
mv $SP $SP.away
LD_LIBRARY_PATH=/usr/prog/libsodium/lib $PY - "$MRROOT" <<'PY' > /tmp/neg.out 2>&1
import importlib, sys
sys.path.insert(0, sys.argv[1])
missing = []
for m in ("tornado", "lmdb", "greenlet", "cffi", "jinja2", "streaming_form_data"):
    try:
        importlib.import_module(m)
    except ImportError:
        missing.append(m)
print("unavailable without the tree: %s" % " ".join(missing))
try:
    importlib.import_module("moonraker.components.database")
    print("database component STILL imported")
except BaseException as exc:
    print("database component fails: %s" % type(exc).__name__)
PY
mv $SP.away $SP
sed -n 's/^/    /p' /tmp/neg.out
if grep -q 'unavailable without the tree: tornado lmdb greenlet cffi jinja2 streaming_form_data' /tmp/neg.out \
   && grep -q 'database component fails' /tmp/neg.out; then
    ok "with the tree removed every third-party import and the database component fail"
else
    bad "negative control did not fail as expected: `cat /tmp/neg.out`"
fi

echo
echo "=== 7. no compiler is reachable, and nothing tried to use one ==="
# The failure mode phase 6 already recorded is a package deciding to BUILD
# something at import time. There is no compiler here, which is the reason
# that failure was fatal rather than slow.
for c in cc gcc mips-linux-gnu-gcc; do
    if command -v $c >/dev/null 2>&1; then
        bad "$c is on PATH in the replica -- this test would not catch a runtime build"
    else
        note "$c: absent, as on a real printer"
    fi
done

echo
echo "=== 8. size of what would be added ==="
note "site-packages: `du -sk $SP | cut -f1` KB, `find $SP -type f | wc -l` files"
note "interpreter  : `du -sk $MODDIR/lib/python3.13 | cut -f1` KB total with it"

echo
echo "=== 9. is setuptools/pkg_resources actually earning its 4.6 MB? ==="
# It is a third of the tree, and it is here for ONE reason: phase 6 recorded a
# trimmed tree in which the lmdb EGG lost pkg_resources, fell back to lmdb's
# cffi path, and tried to run a compiler on the printer at Moonraker startup.
# But this build installs lmdb from a WHEEL with a real CPython extension, not
# an egg -- so the question is whether the insurance is still insuring
# anything. Measured rather than reasoned about: take it away and re-run the
# two things that would break.
mv $SP/setuptools $SP/pkg_resources $SP/_distutils_hack /tmp/ 2>/dev/null
mv $SP/distutils-precedence.pth /tmp/ 2>/dev/null
LD_LIBRARY_PATH=/usr/prog/libsodium/lib $PY - "$MRROOT" "$CONF" <<'PY' > /tmp/nosetup.out 2>&1
import glob, importlib, os, re, sys
sys.path.insert(0, sys.argv[1])
import lmdb, lmdb.cpython
print("lmdb backend without setuptools:", lmdb.cpython.__file__)
import moonraker.server as server
names = list(getattr(server, "CORE_COMPONENTS", []))
for line in open(sys.argv[2]):
    m = re.match(r"\s*\[\s*([A-Za-z0-9_]+)", line)
    if m and m.group(1) != "include":
        names.append(m.group(1))
failures = []
checked = []
for name in dict.fromkeys(names):
    target = "moonraker.components." + name
    try:
        importlib.import_module(target)
        checked.append(name)
    except ModuleNotFoundError as exc:
        if getattr(exc, "name", None) == target:
            continue
        failures.append((name, repr(exc)))
    except Exception as exc:
        failures.append((name, repr(exc)))
for name, err in failures:
    print("  %s: %s" % (name, err))
print("components ok without setuptools: %d" % len(checked) if not failures
      else "%d component(s) need setuptools" % len(failures))
PY
mv /tmp/setuptools /tmp/pkg_resources /tmp/_distutils_hack $SP/ 2>/dev/null
mv /tmp/distutils-precedence.pth $SP/ 2>/dev/null
sed -n 's/^/    /p' /tmp/nosetup.out
if grep -q '^components ok without setuptools: 16' /tmp/nosetup.out; then
    note "setuptools/pkg_resources are NOT needed at runtime by this build --"
    note "  4.9 MB of the tree is insurance against a failure mode (the lmdb"
    note "  EGG's cffi fallback) that installing lmdb as a wheel already removes."
    note "  Dropping them is a size decision, not a correctness one."
else
    ok "setuptools/pkg_resources earn their place: `tail -2 /tmp/nosetup.out`"
fi

echo
[ $FAIL -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $FAIL
