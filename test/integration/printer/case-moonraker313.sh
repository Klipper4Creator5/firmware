#!/bin/sh
# Does Moonraker actually SERVE on the CPython 3.13 this repo cross-builds?
#
# THE DECISIVE GATE for phase 6. case-pyext.sh proved that all 16 components
# IMPORT on 3.13. Importing is not serving: nothing had ever bound :7125 on
# this interpreter. An import exercises module-level code and nothing else --
# it does not open an lmdb environment, does not construct a tornado
# Application, does not run an asyncio event loop on this kernel, and does not
# touch a socket. Every one of those is a separate way for a cross-built
# interpreter to fail, and every one of them is between here and FF_PYTHON
# pointing at 3.13.
#
# It also settles the last /usr/prog string. libnacl is pure Python and
# ctypes-loads libsodium, which on this firmware exists ONLY at
# /usr/prog/libsodium/lib -- so Moonraker's `authorization` component has kept
# one dependency on FlashForge's tree through the whole exercise. sodium.tgz
# is a libsodium cross-built into the mod's own prefix; section 1 takes
# /usr/prog away and makes libnacl work anyway.
#
# The approach is case-moonraker.sh's, deliberately: stage the tree, start it
# the way the shipped `run` script starts it (`python moonraker.py -d
# /usr/data`), wait for the PORT rather than for the process, and then ask the
# HTTP API. What is NOT reused is the s6/S62moonraker machinery -- that is
# already gated against 3.8 and re-running it here would measure init scripts,
# not the interpreter. This runs the entry point directly, with the same
# arguments and the same data path, so that anything that fails is the
# interpreter, the extensions or Moonraker itself.
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }
note(){ echo "  ..    $*"; }
skip(){ echo "  SKIP  $*"; }

MODDIR=/usr/data/anvil
PY=$MODDIR/bin/python3.13
SP=$MODDIR/lib/python3.13/site-packages
MRROOT=/usr/data/mrsrc
MAIN=$MRROOT/moonraker/moonraker.py
DATA=/usr/data
PORT=7125
SODIUM_PROG=/usr/prog/libsodium/lib

# ---- stage ----------------------------------------------------------------
mkdir -p $MODDIR
gzip -dc /mnt/py.tgz     | tar -x -C $MODDIR   || { bad "cannot unpack py.tgz"; exit 1; }
chmod +x $PY 2>/dev/null
mkdir -p $SP
gzip -dc /mnt/ext.tgz    | tar -x -C /tmp      || { bad "cannot unpack ext.tgz"; exit 1; }
cp -a /tmp/site-packages/. $SP/                || { bad "cannot stage site-packages"; exit 1; }
# libsodium goes into the SAME prefix lib/ the stdlib lives under. That is not
# only tidiness -- see section 1c for why the path matters to libnacl.
gzip -dc /mnt/sodium.tgz | tar -x -C $MODDIR   || { bad "cannot unpack sodium.tgz"; exit 1; }
mkdir -p $MRROOT
gzip -dc /mnt/mr.tgz     | tar -x -C $MRROOT   || { bad "cannot unpack mr.tgz"; exit 1; }
# The mod's own moonraker.conf, from assets/, at the path moonraker -d
# /usr/data resolves to. Not a config invented here: a config the mod ships.
gzip -dc /mnt/conf.tgz   | tar -x -C $DATA     || { bad "cannot unpack conf.tgz"; exit 1; }
mkdir -p /usr/data/logs /usr/data/tmp

[ -x "$PY" ]    || { bad "no interpreter at $PY"; exit 1; }
[ -f "$MAIN" ]  || { bad "no moonraker.py at $MAIN"; exit 1; }
note "interpreter: `$PY -c 'import sys;print(sys.version.split()[0])' 2>&1`"
note "libsodium staged: `ls -l $MODDIR/lib/libsodium.so* 2>/dev/null | wc -l` names"

echo
echo "=== 1. libsodium: the last /usr/prog dependency ==="

# ---- 1a. the negative control, FIRST ---------------------------------------
# Everything below is worthless unless libnacl genuinely cannot find a
# libsodium when neither copy is reachable. If it can, some third libsodium is
# on this rootfs and sections 1b/1c are measuring nothing.
mv $MODDIR/lib/libsodium.so     /tmp/ls.so      2>/dev/null
mv $MODDIR/lib/libsodium.so.26  /tmp/ls.so.26   2>/dev/null
mv $MODDIR/lib/libsodium.so.26.2.0 /tmp/ls.so.full 2>/dev/null
# The sentinel is printed with a leading newline and matched anchored, because
# CPython 3.13 echoes the failing SOURCE LINE into its traceback -- a `-c`
# program that contains the word it greps for passes its own negative control.
# That is not hypothetical; it is what the first run of this section did.
env -u LD_LIBRARY_PATH $PY -c \
    'import libnacl; print("\nSENTINEL-loaded", libnacl.nacl._name)' \
    > /tmp/nacl-neg.out 2>&1
if grep -q '^SENTINEL-loaded' /tmp/nacl-neg.out; then
    bad "negative control: libnacl found a libsodium with ours moved aside and no path: `cat /tmp/nacl-neg.out`"
else
    ok "negative control: with ours moved aside and /usr/prog off the path, libnacl fails -- `sed -n '$p' /tmp/nacl-neg.out`"
fi
mv /tmp/ls.so.full $MODDIR/lib/libsodium.so.26.2.0 2>/dev/null
mv /tmp/ls.so.26   $MODDIR/lib/libsodium.so.26     2>/dev/null
mv /tmp/ls.so      $MODDIR/lib/libsodium.so        2>/dev/null

# ---- 1b. ours, on LD_LIBRARY_PATH, with /usr/prog NOWHERE ------------------
LD_LIBRARY_PATH=$MODDIR/lib $PY -c \
    'import libnacl; print("libnacl ok:", libnacl.nacl._name)' \
    > /tmp/nacl-ours.out 2>&1
if grep -q '^libnacl ok' /tmp/nacl-ours.out; then
    ok "libnacl loads OUR libsodium with \$MODDIR/lib on LD_LIBRARY_PATH: `cat /tmp/nacl-ours.out`"
else
    bad "libnacl with \$MODDIR/lib on the path: `tail -3 /tmp/nacl-ours.out`"
fi

# ---- 1c. and with NO path at all -------------------------------------------
# libnacl's own search is worth reading rather than assuming. After
# ctypes.util.find_library and a bare dlopen("libsodium.so") it tries
#
#     libpath = __file__[0 : __file__.find("lib") + 3] + "/libsodium.so"
#
# and __file__ here is $MODDIR/lib/python3.13/site-packages/libnacl/__init__.py
# -- so the first "lib" in that path IS the prefix's own lib/, and the fallback
# resolves to $MODDIR/lib/libsodium.so by ABSOLUTE path. Which means putting
# libsodium in the prefix may cost anvil-env.sh nothing at all. Measured, not
# assumed, because it is a coincidence of the prefix name and a future prefix
# without "lib" in it would break it silently.
env -u LD_LIBRARY_PATH $PY -c \
    'import libnacl; print("libnacl ok:", libnacl.nacl._name)' \
    > /tmp/nacl-nopath.out 2>&1
if grep -q '^libnacl ok' /tmp/nacl-nopath.out; then
    ok "libnacl finds it with LD_LIBRARY_PATH UNSET too: `cat /tmp/nacl-nopath.out`"
    SODIUM_NEEDS_PATH=0
else
    note "with no LD_LIBRARY_PATH libnacl does not find it: `tail -2 /tmp/nacl-nopath.out`"
    note "so \$MODDIR/lib has to go on LD_LIBRARY_PATH -- an anvil-env.sh change"
    SODIUM_NEEDS_PATH=1
fi

# ---- 1d. it is not merely loaded, it computes ------------------------------
# A dlopen that succeeds and a crypto library that works are different claims:
# a wrong-ABI .so fails at dlopen, but a miscompiled one loads and returns
# rubbish. So run a real round trip through it and check the ANSWER.
LD_LIBRARY_PATH=$MODDIR/lib $PY - <<'EOP' > /tmp/nacl-use.out 2>&1
import binascii, ctypes
import libnacl
import libnacl.sign
libnacl.nacl.sodium_version_string.restype = ctypes.c_char_p
print("sodium_version_string(): %s" % libnacl.nacl.sodium_version_string().decode())
# A KNOWN-ANSWER test, because a dlopen that succeeds and a crypto library
# that is correct are different claims -- a miscompiled one loads and returns
# rubbish. crypto_generichash is BLAKE2b at libsodium's default 32-byte
# output, and the ANSWER is not written down here: it is computed by CPython's
# own _blake2 extension, in this process, on this kernel. Two independent
# mipsel builds of the same algorithm agreeing is a stronger statement than a
# constant pasted from a spec -- and a constant pasted from a spec is how the
# first version of this check failed, against a correct library, because 512
# is the algorithm's default and 32 bytes is libsodium's.
import hashlib
got  = binascii.hexlify(libnacl.crypto_generichash(b"nozzle at 210")).decode()
want = hashlib.blake2b(b"nozzle at 210", digest_size=32).hexdigest()
print("blake2b-256: libsodium=%s" % got)
print("             cpython  =%s" % want)
assert got == want, (got, want)
# And then EXACTLY what moonraker/components/authorization.py imports and
# uses: libnacl.sign.Signer / Verifier, the ed25519 pair behind its JWTs.
signer = libnacl.sign.Signer()
sig = signer.signature(b"nozzle at 210")
ver = libnacl.sign.Verifier(signer.hex_vk())
assert ver.verify(sig + b"nozzle at 210") == b"nozzle at 210"
try:
    ver.verify(sig + b"nozzle at 211")
    print("FORGERY ACCEPTED")
except ValueError:
    print("ed25519 sign/verify ok, and a tampered message is rejected")
print("libsodium works")
EOP
if grep -q '^libsodium works' /tmp/nacl-use.out; then
    ok "and it computes -- not merely loads:"
    grep -v '^libsodium works' /tmp/nacl-use.out | sed 's/^/        /'
else
    bad "libsodium loaded but does not work:"
    sed 's/^/        /' /tmp/nacl-use.out | tail -8
fi

# ---- 1e. the authorization component, with /usr/prog unreachable -----------
# The component that caused the original outage, on the new interpreter, with
# the library it needs coming from our prefix.
LD_LIBRARY_PATH=$MODDIR/lib $PY -c "
import sys; sys.path.insert(0, '$MRROOT')
import moonraker.components.authorization as a
print('authorization imported from', a.__file__)
" > /tmp/auth.out 2>&1
grep -q '^authorization imported' /tmp/auth.out \
    && ok "moonraker's authorization component imports on 3.13 with no /usr/prog libsodium" \
    || bad "authorization: `tail -3 /tmp/auth.out`"

echo
echo "=== 2. THE DECISIVE ONE: does it SERVE? ==="

# The environment the server gets: LD_LIBRARY_PATH is UNSET, not merely
# purged of /usr/prog. That is the strongest form of the claim and the one
# worth measuring -- the interpreter is statically linked against its seven C
# libraries, every extension was linked by the same toolchain, and section 1c
# showed libnacl resolving the prefix path by itself. If anything in the
# server needs a search path, this is where it says so.
# TMPDIR is off the ramdisk, exactly as payload/etc/s6/moonraker/run sets it.
MRENV="TMPDIR=/usr/data/tmp"
mrun() { env -u LD_LIBRARY_PATH $MRENV "$@"; }

port_listening() {
    awk -v p=":`printf '%04X' $PORT`" '$2 ~ p"$" && $4 == "0A" { f = 1 }
                                       END { exit !f }' /proc/net/tcp 2>/dev/null
}

# ---- 2a. negative control: nothing is listening yet ------------------------
if port_listening; then
    bad "negative control: something is ALREADY listening on :$PORT"
else
    ok "negative control: nothing is listening on :$PORT before we start"
fi

# ---- 2b. start it ----------------------------------------------------------
# Exactly the command line payload/etc/s6/moonraker/run execs, with our
# interpreter substituted for FF_PYTHON and the log named so it cannot be
# confused with a 3.8 run.
LOG=/usr/data/logs/moonraker313.log
rm -f $LOG
echo "  ..    starting: $PY $MAIN -d $DATA -l $LOG"
# NOT `mrun ... &`. Backgrounding a shell FUNCTION makes busybox sh fork a
# subshell and hand back the SUBSHELL's pid, which still carries the case
# script's own cmdline -- so every check below reads /proc of the wrong
# process, the SIGTERM at the end kills the wrong process, and the server
# survives into the next section. Measured, and it cost a replica run. A
# simple command is exec'd by the background child, so $! is the server.
env -u LD_LIBRARY_PATH $MRENV $PY $MAIN -d $DATA -l $LOG > /tmp/mr-stdout.txt 2>&1 &
MRPID=$!
note "pid $MRPID"
# And prove that, rather than trusting it: a pid whose cmdline is this script
# is the bug above, not a server.
note "pid $MRPID cmdline: `tr '\0' ' ' < /proc/$MRPID/cmdline 2>/dev/null`"

waited=0
while [ $waited -lt 240 ]; do
    port_listening && break
    kill -0 $MRPID 2>/dev/null || break
    sleep 3
    waited=$((waited + 3))
done

if ! kill -0 $MRPID 2>/dev/null; then
    bad "moonraker EXITED before binding :$PORT (after ${waited}s)"
    echo "  ---- stdout/stderr ----"
    sed 's/^/      /' /tmp/mr-stdout.txt | tail -n 40
    echo "  ---- $LOG ----"
    tail -n 60 $LOG 2>/dev/null | sed 's/^/      /'
    echo
    echo "RESULT: FAIL (moonraker does not serve on 3.13)"
    exit 1
fi

if port_listening; then
    ok "moonraker BOUND :$PORT after ${waited}s, under $PY"
else
    bad "moonraker is still alive after ${waited}s but never bound :$PORT"
    tail -n 40 $LOG 2>/dev/null | sed 's/^/      /'
fi

# ---- 2c. it is our interpreter holding the socket --------------------------
CMD=`tr '\0' ' ' < /proc/$MRPID/cmdline 2>/dev/null`
case "$CMD" in
    *"$PY"*)  ok "the process is running under $PY" ;;
    *)        bad "the process is '$CMD', not our interpreter" ;;
esac
case "$CMD" in
    *"$MAIN"*) ok "and it is running $MAIN" ;;
    *)         bad "it is not running $MAIN: $CMD" ;;
esac

# ---- 2d. the API answers ---------------------------------------------------
# The HTTP client is our own 3.13, which is convenient and also honest: if the
# client cannot make an HTTP request the interpreter has a bigger problem than
# Moonraker. Every call goes through one helper so a failure names the URL.
cat > /tmp/get.py <<'EOP'
import json, sys, urllib.request
url = sys.argv[1]
data = None
method = "GET"
if len(sys.argv) > 2:
    method = "POST"
    data = sys.argv[2].encode()
req = urllib.request.Request(url, data=data, method=method,
                             headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=20) as r:
        body = r.read().decode()
    print("HTTP %d" % r.status)
    print(body)
except Exception as exc:
    print("REQUEST FAILED: %r" % (exc,))
    sys.exit(1)
EOP

get() { mrun $PY /tmp/get.py "http://127.0.0.1:$PORT$1" ${2:+"$2"}; }

# /server/info -- the endpoint every UI hits first, and the one that names the
# components the server actually LOADED. That list is the point: a component
# that imports but throws in its constructor never reaches it.
get /server/info > /tmp/info.out 2>&1
if grep -q '^HTTP 200' /tmp/info.out; then
    ok "GET /server/info answers 200"
    mrun $PY - <<'EOP' > /tmp/info2.out 2>&1
import json
raw = open("/tmp/info.out").read().split("\n", 1)[1]
d = json.loads(raw)["result"]
comps = sorted(d.get("components", []))
fail = sorted(d.get("failed_components", []))
print("klippy_connected=%s klippy_state=%s api_version=%s" % (
    d.get("klippy_connected"), d.get("klippy_state"), d.get("api_version_string")))
print("moonraker_version=%s" % d.get("moonraker_version"))
print("components(%d): %s" % (len(comps), ", ".join(comps)))
print("failed_components(%d): %s" % (len(fail), ", ".join(map(str, fail))))
print("warnings: %s" % (d.get("warnings"),))
EOP
    sed 's/^/      /' /tmp/info2.out
    NCOMP=`sed -n 's/^components(\([0-9]*\)).*/\1/p' /tmp/info2.out`
    [ -n "$NCOMP" ] && [ "$NCOMP" -ge 16 ] \
        && ok "the JSON names $NCOMP loaded components" \
        || bad "server/info reports only '$NCOMP' components"
    grep -q '^failed_components(0)' /tmp/info2.out \
        && ok "no failed components" \
        || bad "`grep '^failed_components' /tmp/info2.out`"
else
    bad "GET /server/info: `tail -2 /tmp/info.out`"
fi

# A SECOND endpoint, and deliberately one served by a different component:
# /server/info is the Server object itself, /machine/system_info is the
# `machine` component reading this box's /proc and /sys. Two endpoints from
# two components is the difference between "tornado routes" and "Moonraker
# runs".
get /machine/system_info > /tmp/sys.out 2>&1
if grep -q '^HTTP 200' /tmp/sys.out; then
    ok "GET /machine/system_info answers 200"
    mrun $PY - <<'EOP' 2>&1 | sed 's/^/      /'
import json
raw = open("/tmp/sys.out").read().split("\n", 1)[1]
si = json.loads(raw)["result"]["system_info"]
cpu = si.get("cpu_info", {})
print("cpu: %s x%s  %s" % (cpu.get("processor"), cpu.get("cpu_count"),
                           cpu.get("model", "")[:40]))
print("total_memory: %s %s" % (cpu.get("total_memory"), cpu.get("memory_units")))
print("python: %s" % (si.get("python", {}).get("version_string"),))
print("keys: %s" % ", ".join(sorted(si)))
EOP
else
    bad "GET /machine/system_info: `tail -2 /tmp/sys.out`"
fi

# A third, from `webcam` -- the component the mod's moonraker.conf configures
# and the reason the pin is what it is.
get /server/webcams/list > /tmp/cam.out 2>&1
grep -q '^HTTP 200' /tmp/cam.out \
    && ok "GET /server/webcams/list answers 200 (`sed -n '2p' /tmp/cam.out | cut -c1-90`)" \
    || note "GET /server/webcams/list: `tail -1 /tmp/cam.out`"

# ---- 2e. THE DATABASE, which is the whole reason for the 3.13 exercise -----
# This pin keeps its database in lmdb (v0.9.0 is where Moonraker moved to
# sqlite, and MOONRAKER_VERSION is deliberately the last commit before that).
# So what is being proved here is the lmdb C extension driving a real
# environment from inside the running server -- write over HTTP, read back
# over HTTP, and then look at the files on disk.
DBNS=anvil_gate
get /server/database/item "{\"namespace\":\"$DBNS\",\"key\":\"phase6.probe\",\"value\":{\"nozzle\":210,\"ok\":true}}" \
    > /tmp/db-w.out 2>&1
if grep -q '^HTTP 200' /tmp/db-w.out; then
    ok "POST /server/database/item wrote to namespace '$DBNS'"
else
    bad "database write: `tail -2 /tmp/db-w.out`"
fi
get "/server/database/item?namespace=$DBNS&key=phase6.probe" > /tmp/db-r.out 2>&1
if grep -q '^HTTP 200' /tmp/db-r.out && grep -q '210' /tmp/db-r.out; then
    ok "GET reads it back: `sed -n '2p' /tmp/db-r.out | cut -c1-100`"
else
    bad "database read: `tail -2 /tmp/db-r.out`"
fi
get /server/database/list > /tmp/db-l.out 2>&1
grep -q "$DBNS" /tmp/db-l.out \
    && ok "and the namespace is listed: `sed -n '2p' /tmp/db-l.out | cut -c1-110`" \
    || bad "namespace not listed: `tail -1 /tmp/db-l.out`"
# On disk. An lmdb environment is data.mdb + lock.mdb, and a data.mdb of
# nonzero size is the claim "there is a database" made without asking the
# process that wrote it.
if [ -f $DATA/database/data.mdb ]; then
    ok "lmdb environment on disk: `ls -l $DATA/database/data.mdb | awk '{print $5}'` bytes at $DATA/database/data.mdb"
else
    note "no $DATA/database/data.mdb -- looking for one:"
    find $DATA -name 'data.mdb' 2>/dev/null | sed 's/^/      /'
    bad "no lmdb data.mdb where the database component should have made one"
fi
# And the lmdb the SERVER is using is the CPython extension, not the cffi
# fallback that would try to run a compiler on this printer.
mrun $PY -c \
    'import lmdb, lmdb.cpython; print("lmdb backend:", lmdb.__file__, lmdb.version())' \
    2>&1 | sed 's/^/      /'

# ---- 2f. zero /usr/prog, read off the RUNNING process ----------------------
# Not off a python that imported some modules -- off the pid that is holding
# :7125, with every component loaded and the database open. This is the claim
# the whole phase is for.
echo "  ..    /proc/$MRPID/maps:"
awk '{print $NF}' /proc/$MRPID/maps 2>/dev/null | grep '^/' | sort -u > /tmp/maps.txt
sed 's/^/        /' /tmp/maps.txt
NPROG=`grep -c '^/usr/prog' /tmp/maps.txt`
[ "$NPROG" = 0 ] \
    && ok "the RUNNING moonraker maps 0 libraries under /usr/prog" \
    || bad "$NPROG libraries under /usr/prog are mapped by the running moonraker"
if grep -q "^$MODDIR/lib/libsodium" /tmp/maps.txt; then
    ok "and libsodium is mapped from the prefix: `grep libsodium /tmp/maps.txt`"
else
    bad "our libsodium is NOT mapped by the running server -- authorization did not need it, or found another"
fi

# ---- 2g. it stays up -------------------------------------------------------
# A process that binds a port, answers once and exits is not a server. Two
# minutes is not an endurance test and is not claimed as one; it is long
# enough to catch an event loop that dies on its first idle timer, a component
# whose periodic callback throws, and the proc_stats sampler, which runs every
# second and touches /proc on this kernel.
BEFORE=`date +%s`
n=0
while [ $n -lt 120 ]; do
    sleep 10
    n=$((n + 10))
    kill -0 $MRPID 2>/dev/null || break
done
if kill -0 $MRPID 2>/dev/null; then
    ok "still alive ${n}s later (pid $MRPID)"
    port_listening && ok "and still listening on :$PORT" \
                   || bad "alive but no longer listening on :$PORT"
    get /server/info > /tmp/info3.out 2>&1
    grep -q '^HTTP 200' /tmp/info3.out \
        && ok "and still answers /server/info after ${n}s" \
        || bad "stopped answering after ${n}s: `tail -1 /tmp/info3.out`"
    # proc_stats runs a 1Hz sampler; if it were throwing, the log would say so
    # every second. Reading the log for tracebacks is the cheap way to catch a
    # component that is failing quietly behind a working endpoint.
    NTB=`grep -c 'Traceback' $LOG 2>/dev/null`
    [ "$NTB" = 0 ] \
        && ok "no tracebacks in $LOG" \
        || note "$NTB traceback(s) in the log:"
    [ "$NTB" = 0 ] || grep -A6 'Traceback' $LOG | head -40 | sed 's/^/      /'
else
    bad "moonraker DIED during the ${n}s soak"
    tail -n 40 $LOG | sed 's/^/      /'
fi

# ---- 2h. the shutdown, and the log ----------------------------------------
echo "  ..    log head:"
head -n 25 $LOG 2>/dev/null | sed 's/^/      /'
kill -TERM $MRPID 2>/dev/null
w=0
while [ $w -lt 30 ] && kill -0 $MRPID 2>/dev/null; do sleep 2; w=$((w + 2)); done
kill -0 $MRPID 2>/dev/null && { kill -9 $MRPID 2>/dev/null; note "needed SIGKILL"; } \
                           || ok "SIGTERM stopped it in ${w}s"
sleep 3
port_listening && bad ":$PORT still bound after the server exited" \
               || ok ":$PORT released"

echo
echo "=== 3. negative control: it is OUR tree that is doing this ==="
# Move site-packages aside and start the same command line again. If it still
# comes up, then FlashForge's 3.8 site-packages are somehow being reached and
# every PASS above belongs to somebody else's build.
mv $SP $SP.away
env -u LD_LIBRARY_PATH $MRENV $PY $MAIN -d $DATA -l /usr/data/logs/mr-neg.log > /tmp/mr-neg.txt 2>&1 &
NEGPID=$!
w=0
while [ $w -lt 60 ]; do
    port_listening && break
    kill -0 $NEGPID 2>/dev/null || break
    sleep 3; w=$((w + 3))
done
if port_listening; then
    bad "negative control: moonraker bound :$PORT with site-packages moved away"
    kill -9 $NEGPID 2>/dev/null
else
    ok "negative control: with site-packages moved away it never binds -- `tail -2 /tmp/mr-neg.txt /usr/data/logs/mr-neg.log 2>/dev/null | grep -i 'error\|no module' | head -1`"
fi
kill -9 $NEGPID 2>/dev/null
mv $SP.away $SP

echo
if [ "$SODIUM_NEEDS_PATH" = 1 ]; then
    echo "anvil-env.sh WOULD NEED: $MODDIR/lib on LD_LIBRARY_PATH"
else
    echo "anvil-env.sh needs NO new LD_LIBRARY_PATH entry (libnacl resolves the prefix path itself)"
fi
echo "and $SODIUM_PROG can come OFF the list."
echo
[ "$FAIL" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit $FAIL
