#!/bin/sh
# Is every directory in ANVIL_LIBS actually load-bearing, and is every one
# that was taken out actually dead?
#
# WHY THIS EXISTS. anvil-env.sh used to put TEN /usr/prog library directories
# on LD_LIBRARY_PATH for every process the mod starts, and the comment
# defending that said the list was "the union, deliberately" -- the idea being
# that what moonraker links against is a property of the component set in
# moonraker.conf, which a user edits, so a caller handed everything could not
# be broken by a config change. That was an argument, not a measurement. Six
# of the ten turned out to have no Python consumer at all on this firmware;
# the single consumer of ffmpeg, x264, opencv, nim and libzip between them was
# FlashForge's own firmwareExe, which this mod replaces with a shell script,
# and the one that ever did have a Python consumer -- curl, through pycurl --
# cannot be reached because pycurl does not import here at all.
#
# So the list is four now, and a shorter list is only an improvement if it is
# still correct. Both halves of that are questions about behaviour, and both
# are answered here by running the printer's own interpreter rather than by
# reading anything:
#
#   THE FOUR ARE REQUIRED. Each is removed from LD_LIBRARY_PATH one at a time
#   and something is made to fail: for Python-3.8.2 and openssl-1.0.2d the
#   interpreter does not start at all (openssl because libpython3.8.so.1.0
#   itself has DT_NEEDED on libssl.so.1.0.0 -- _ssl and zlib are BUILTIN and
#   statically linked in, so this has nothing to do with `import ssl`), for
#   libffi-3.4.4 it is `import ctypes`, for libsodium it is `import libnacl`.
#   These are the negative controls and they carry the weight: without them
#   this case would pass just as happily against a list of forty directories.
#
#   THE SIX ARE DEAD. The strongest available check is not "nothing greps for
#   them" but that a process running on the four-entry path maps none of the
#   six -- and then, so that this is a statement about the LIBRARIES rather
#   than about the path, that the same process handed the OLD ten-entry path
#   still maps none of them. /proc/PID/maps is the authority on what a running
#   process has loaded, so that is what is read.
#
# And that the printer still works on four: the interpreter runs, ctypes
# imports, and every Moonraker component this printer is configured for
# imports -- checked the way case-moonraker.sh checks it, from Moonraker's own
# CORE_COMPONENTS plus the sections of the real moonraker.conf and anything it
# includes, because a list of component names retyped here would go stale the
# moment somebody configured one we never thought about.
#
# The payload under test is mounted at /tmp/payload.
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }
skip() { echo "  SKIP  $*"; }
note() { echo "  ..    $*"; }

MODDIR=/usr/data/anvil
PAYLOAD=/tmp/payload
PY=/usr/prog/Python-3.8.2/bin/python3
MRROOT=$MODDIR
# FlashForge's own 2022 tree, which the mod no longer runs. Named here only as
# the stand-in described at the staging step below, exactly as case-moonraker
# names it.
STOCK_MR=/usr/prog/moonraker/moonraker/moonraker

# THE SIX THAT WENT. They are written down here and nowhere else, because they
# are no longer in the shipped file to be read out of it -- that is the whole
# point. If one of them is ever put back, this list and the check at section 6
# are what make somebody say out loud which process maps it.
GONE="/usr/prog/curl-7.55.1/lib
/usr/prog/ffmpeg-402/lib
/usr/prog/x264/lib
/usr/prog/opencv-4.2/lib
/usr/prog/nim/lib
/usr/prog/libzip-1.10.1/lib"

[ -d "$PAYLOAD" ] || { bad "no payload mounted at $PAYLOAD"; exit 1; }
[ -x "$PY" ] || { bad "no interpreter at $PY"; exit 1; }

# ---- install the payload, as run-append.sh does ----------------------------
mkdir -p $MODDIR/init.d
cp -f $PAYLOAD/anvil-env.sh $MODDIR/ 2>/dev/null
[ -f $MODDIR/anvil-env.sh ] || { bad "the payload ships no anvil-env.sh"; exit 1; }
ok "payload installed to $MODDIR"

# The Moonraker tree, at the path the mod runs it from. Same staging and the
# same honesty as case-moonraker.sh: the mod's own tree is fetched into
# work/modpayload by bin/patch.sh and is not on this mount unless the caller
# put it there, so the printer's own 2022 tree stands in, and section 5 says
# which of the two it got.
if [ -d $PAYLOAD/moonraker ]; then
    rm -rf $MODDIR/moonraker
    cp -a $PAYLOAD/moonraker $MODDIR/moonraker
    ok "the payload's own Moonraker staged at $MODDIR/moonraker"
elif [ -d "$STOCK_MR" ]; then
    rm -rf $MODDIR/moonraker
    cp -a "$STOCK_MR" $MODDIR/moonraker
    skip "the payload mount carries no moonraker/ -- the printer's own tree stands in at $MODDIR/moonraker"
else
    skip "no Moonraker tree available at all -- section 5 will report it"
fi

# ---- 1. the environment is load-bearing at all -----------------------------
# If the interpreter runs with no LD_LIBRARY_PATH whatsoever then this whole
# file measures nothing: every "it failed without X" below would have to be
# read as "it failed for some other reason".
if env -u LD_LIBRARY_PATH "$PY" -c 'pass' >/dev/null 2>&1; then
    bad "the interpreter runs with NO LD_LIBRARY_PATH -- nothing below is a real negative control"
else
    ok "without LD_LIBRARY_PATH the interpreter does not start -- the path is load-bearing"
fi

# ---- 2. what the shipped file actually exports -----------------------------
# Read out of the installed file by SOURCING it, not by grepping it: the
# question is what a caller gets, and a caller sources it.
. $MODDIR/anvil-env.sh
FOUR="$LD_LIBRARY_PATH"
note "LD_LIBRARY_PATH after sourcing anvil-env.sh: $FOUR"

for d in /usr/prog/Python-3.8.2/lib /usr/prog/openssl-1.0.2d/lib \
         /usr/prog/libffi-3.4.4/lib /usr/prog/libsodium/lib; do
    if [ ! -d "$d" ]; then
        skip "$d does not exist on this printer"
        continue
    fi
    case ":$FOUR:" in
        *":$d:"*) ok "$d is exported" ;;
        *)        bad "$d is NOT exported -- something the mod runs will not start" ;;
    esac
done

# And none of the six. This is the cheap half of the claim -- section 6 is the
# half that means something -- but a path that still carries them would make
# section 6 pass for the wrong reason, so it is asked first.
for d in $GONE; do
    case ":$FOUR:" in
        *":$d:"*) bad "$d is back on the path with nothing shown to map it" ;;
        *)        ok "$d is not on the path" ;;
    esac
done

# ---- 3. the four, taken away one at a time ---------------------------------
# The point of each entry, stated as the failure that happens without it. Each
# probe is chosen to be the FIRST thing that breaks, so that a pass here means
# the entry is required and not merely present:
#
#   Python-3.8.2    the interpreter cannot load libpython3.8.so.1.0
#   openssl-1.0.2d  the interpreter cannot load libssl.so.1.0.0, which
#                   libpython itself needs -- so it dies before running code
#   libffi-3.4.4    the interpreter is fine and `import ctypes` is not
#   libsodium       the interpreter is fine and `import libnacl` is not
#
# A "without it, still fine" result is not a harness problem to route around:
# it is this gate saying the entry is cargo and should go the way the six did.
without() {
    echo "$FOUR" | tr ':' '\n' | grep -v "^$1\$" | tr '\n' ':' | sed 's/:*$//'
}

drop_check() {
    _dir=$1; _probe=$2; _what=$3
    if [ ! -d "$_dir" ]; then
        skip "$_dir is not installed here -- cannot take it away"
        return
    fi
    _path=`without "$_dir"`
    if [ "$_path" = "$FOUR" ]; then
        bad "removing $_dir from the path changed nothing -- this control is broken"
        return
    fi
    if LD_LIBRARY_PATH="$_path" "$PY" -c "$_probe" >/tmp/drop.out 2>&1; then
        bad "WITHOUT $_dir, $_what still worked -- that entry is cargo"
    else
        ok "without $_dir, $_what fails -- \"`tail -1 /tmp/drop.out | cut -c1-90`\""
    fi
}

echo
echo "--- 3. negative controls: each entry removed on its own ---"
drop_check /usr/prog/Python-3.8.2/lib   'pass'            "starting the interpreter"
drop_check /usr/prog/openssl-1.0.2d/lib 'pass'            "starting the interpreter"
drop_check /usr/prog/libffi-3.4.4/lib   'import ctypes'   "import ctypes"
drop_check /usr/prog/libsodium/lib      'import libnacl'  "import libnacl"

# The two interpreter-does-not-start controls above are the same observation
# twice unless openssl fails for its OWN reason, so the reason is asked for
# directly: libpython3.8.so.1.0 has DT_NEEDED on libssl.so.1.0.0, and the
# rootfs has only libssl.so.1.1, which is a different soname and cannot
# satisfy it. readelf is not on every busybox, so this degrades to strings and
# then skips -- it is corroboration, and section 3 is the measurement.
LIBPY=/usr/prog/Python-3.8.2/lib/libpython3.8.so.1.0
if [ -f "$LIBPY" ]; then
    if command -v readelf >/dev/null 2>&1; then
        if readelf -d "$LIBPY" 2>/dev/null | grep -q 'libssl\.so\.1\.0\.0'; then
            ok "readelf: libpython3.8.so.1.0 has DT_NEEDED on libssl.so.1.0.0 -- the interpreter itself needs it, nothing to do with import ssl"
        else
            bad "readelf: libpython3.8.so.1.0 does NOT need libssl.so.1.0.0 -- then why did the openssl control fail?"
        fi
    elif command -v strings >/dev/null 2>&1; then
        strings "$LIBPY" 2>/dev/null | grep -q '^libssl\.so\.1\.0\.0$' \
            && ok "strings: libpython3.8.so.1.0 names libssl.so.1.0.0" \
            || skip "strings found no libssl.so.1.0.0 in libpython -- section 3 is the measurement either way"
    else
        skip "no readelf or strings here -- section 3 stands on its own"
    fi
fi

# ---- 4. on the four-entry path, the things the mod runs still work ---------
echo
echo "--- 4. and the four-entry path is enough ---"
"$PY" -c 'print("interpreter ok")' >/tmp/four.out 2>&1
grep -q '^interpreter ok' /tmp/four.out \
    && ok "the interpreter starts on the four-entry path" \
    || bad "the interpreter does not start on the shipped path: `tail -1 /tmp/four.out`"

"$PY" -c 'import ctypes; print("ctypes ok")' >/tmp/four-ctypes.out 2>&1
grep -q '^ctypes ok' /tmp/four-ctypes.out \
    && ok "import ctypes works -- libffi.so.8 was found" \
    || bad "import ctypes failed on the shipped path: `tail -1 /tmp/four-ctypes.out`"

"$PY" -c 'import libnacl; print("libnacl ok")' >/tmp/four-nacl.out 2>&1
if grep -q '^libnacl ok' /tmp/four-nacl.out; then
    ok "import libnacl works -- libsodium was found"
else
    skip "libnacl does not import here: `tail -1 /tmp/four-nacl.out | cut -c1-70`"
fi

# ---- 5. every Moonraker component this printer is configured for imports ---
# The same check case-moonraker.sh runs, and deliberately the same code: the
# component list comes from Moonraker's own CORE_COMPONENTS plus every section
# in moonraker.conf and anything it [include]s, so a user's own sections in
# moonraker-custom.conf are followed too. What is different here is only the
# question being asked of it -- not "does this build load" but "does this build
# still load with six directories gone from the loader path".
#
# WHICH CONFIG. The mod's own is assets/moonraker.conf, which bin/patch.sh
# stages into the built payload as config/moonraker.conf; this mount is the
# SOURCE payload, so it is there only when the caller staged it. The printer's
# live /usr/data/config/moonraker.conf is the fallback, and it is the file the
# printer would really be started with.
MRCONF=""
for c in $PAYLOAD/config/moonraker.conf /usr/data/config/moonraker.conf; do
    [ -f "$c" ] && { MRCONF=$c; break; }
done
echo
echo "--- 5. moonraker components, on the four-entry path ---"
if [ ! -d "$MRROOT/moonraker" ]; then
    skip "no moonraker package at $MRROOT/moonraker"
elif [ -z "$MRCONF" ]; then
    skip "no moonraker.conf on this printer -- nothing says which components are enabled"
else
    note "components from CORE_COMPONENTS plus the sections of $MRCONF"
    "$PY" - "$MRROOT" "$MRCONF" <<'PY' >/tmp/mr-pre.out 2>&1
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
for name in dict.fromkeys(names):
    target = "moonraker.components." + name
    try:
        importlib.import_module(target)
    except ModuleNotFoundError as exc:
        # A component that does not exist is fine -- that is a config section
        # like [server]. A missing DEPENDENCY of one that does exist is the
        # whole point.
        if getattr(exc, "name", None) == target:
            continue
        failures.append((name, repr(exc)))
    except Exception as exc:
        # libnacl raises OSError, not ImportError, when libsodium is missing.
        failures.append((name, repr(exc)))

for name, err in failures:
    print("  %s: %s" % (name, err))
print("components ok: %d" % len(dict.fromkeys(names)) if not failures
      else "%d component(s) will not load" % len(failures))
raise SystemExit(1 if failures else 0)
PY
    if grep -q '^components ok:' /tmp/mr-pre.out; then
        ok "`grep '^components ok:' /tmp/mr-pre.out` with six directories gone from the path"
    elif grep -q 'moonraker.server does not import' /tmp/mr-pre.out; then
        # FlashForge's 2022 tree is the older app.py layout with no
        # moonraker.server to enter at. A real answer about a real tree; the
        # mod's own build is checked by case-moonraker.sh and the install gate.
        skip "the installed tree is the old layout: `tail -1 /tmp/mr-pre.out`"
    else
        bad "components will not load on the four-entry path: `tail -4 /tmp/mr-pre.out`"
    fi
fi

# ---- 6. the six, proved dead by /proc/PID/maps -----------------------------
# A running python is asked what it has actually loaded. The probe imports the
# things the mod's processes import -- ctypes, libnacl, and as much of
# moonraker as this tree allows -- and then sits still so its maps can be read.
#
# TWICE, and the second run is the one that matters. On the four-entry path,
# "none of the six is mapped" is nearly a tautology: they are not on the path,
# so of course nothing found them. So the same probe is run again with the OLD
# TEN-ENTRY path -- every directory available to it, exactly as before this
# change -- and if it still maps none of the six, then removing them took
# nothing away from any process this mod starts. That is the claim.
echo
echo "--- 6. /proc/PID/maps: what a real process loads ---"
cat > /tmp/libprobe.py <<'EOPROBE'
# Import what the mod's own processes import, then hold still. Everything
# after ctypes is best-effort: this runs on printers where the moonraker tree
# is FlashForge's old one, and the point of the probe is the MAPS, so a probe
# that refused to start on a tree it could not import would measure nothing.
import sys, time
import ctypes                                        # noqa: F401
try:
    import libnacl                                   # noqa: F401
except Exception:
    pass
if len(sys.argv) > 1:
    sys.path.insert(0, sys.argv[1])
    try:
        import moonraker.server                      # noqa: F401
        import importlib, pkgutil
        import moonraker.components as comps
        for m in pkgutil.iter_modules(comps.__path__):
            try:
                importlib.import_module("moonraker.components." + m.name)
            except Exception:
                pass
    except Exception:
        pass
sys.stdout.write("probe up\n")
sys.stdout.flush()
time.sleep(300)
EOPROBE

OLDTEN="/usr/prog/Python-3.8.2/lib:/usr/prog/openssl-1.0.2d/lib:/usr/prog/curl-7.55.1/lib:/usr/prog/ffmpeg-402/lib:/usr/prog/x264/lib:/usr/prog/libffi-3.4.4/lib:/usr/prog/libsodium/lib:/usr/prog/opencv-4.2/lib:/usr/prog/nim/lib:/usr/prog/libzip-1.10.1/lib"

maps_of() {
    # Start the probe on the given LD_LIBRARY_PATH, wait for it to say it is
    # up, and leave its maps in /tmp/probe.maps. Echoes the pid, or nothing.
    _out=/tmp/probe.$$.out
    rm -f $_out /tmp/probe.maps
    LD_LIBRARY_PATH="$1" "$PY" /tmp/libprobe.py "$MRROOT" > $_out 2>&1 &
    _pid=$!
    _w=0
    while [ $_w -lt 90 ]; do
        grep -q '^probe up' $_out 2>/dev/null && break
        kill -0 $_pid 2>/dev/null || break
        sleep 2
        _w=$((_w + 2))
    done
    if ! grep -q '^probe up' $_out 2>/dev/null; then
        kill -9 $_pid 2>/dev/null
        return 1
    fi
    cp /proc/$_pid/maps /tmp/probe.maps 2>/dev/null
    kill -9 $_pid 2>/dev/null
    [ -s /tmp/probe.maps ]
}

check_maps() {
    _label=$1
    # POSITIVE CONTROL FOR THE METHOD. If /proc/PID/maps carried no /usr/prog
    # library at all -- an unreadable maps, a probe that died, a kernel that
    # reports nothing -- then "none of the six is mapped" would be true of a
    # file that says nothing about anything. libpython is the one library this
    # process cannot be running without.
    if grep -q '/usr/prog/Python-3.8.2/lib/libpython3\.8\.so' /tmp/probe.maps; then
        ok "$_label: the probe maps libpython3.8.so.1.0 -- maps is telling us what is loaded"
    else
        bad "$_label: the probe's maps has no libpython in it -- this measurement is worthless"
        return
    fi
    note "$_label: `grep -c /usr/prog /tmp/probe.maps` mapped regions under /usr/prog"
    _hits=""
    for d in $GONE; do
        grep -qF "$d/" /tmp/probe.maps && _hits="$_hits $d"
    done
    if [ -z "$_hits" ]; then
        ok "$_label: none of the six removed directories is mapped"
    else
        bad "$_label: still mapped, so they were NOT dead:$_hits"
    fi
}

if maps_of "$FOUR"; then
    check_maps "on the four shipped entries"
else
    bad "the probe never came up on the shipped path -- see /tmp/probe.$$.out"
fi

# The one that means something: everything on the path, and still nothing
# reaches for the six.
if maps_of "$OLDTEN"; then
    check_maps "with the OLD ten-entry path"
    # And the same process, on the same path, does map the four -- so the six
    # were not skipped because the loader gave up early.
    _miss=""
    for d in /usr/prog/libffi-3.4.4/lib /usr/prog/libsodium/lib; do
        [ -d "$d" ] || continue
        grep -qF "$d/" /tmp/probe.maps || _miss="$_miss $d"
    done
    [ -z "$_miss" ] \
        && ok "with the OLD ten-entry path the probe does map libffi and libsodium -- it was loading libraries, it just never wanted the six" \
        || note "not mapped by this probe:$_miss (this tree may not import the component that needs them)"
else
    bad "the probe never came up on the old ten-entry path -- the interesting half of section 6 did not run"
fi

echo
[ $FAIL = 0 ] && echo "libpath: all checks passed" || echo "libpath: FAILURES"
exit $FAIL
