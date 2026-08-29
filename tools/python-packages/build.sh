#!/bin/bash
# ---------------------------------------------------------------------------
# Cross-build the third-party Python packages Moonraker and klippy import,
# for the CPython 3.13 that tools/python/build.sh already produces for the
# FlashForge Creator 5 Pro (Ingenic mipsel).
#
# SPIKE. Nothing here is wired into bin/patch.sh yet.
#
# Same non-negotiables as tools/python/build.sh, for the same reasons:
#
#   * e_flags 0x70001405 for an EXEC, 0x70001407 for a DYN (EF_MIPS_PIC).
#     Every .so this produces is gated; a legacy-NaN wheel imports fine on the
#     host and fails on the printer with nothing but ENOEXEC to say why.
#   * -EL -mnan=2008 must reach the COMPILE and the LINK of every object.
#     setuptools does not forward CFLAGS to its link line, so the flags are
#     baked into PATH wrappers around the gcc driver and no build system gets
#     a vote.
#   * glibc toolchain only. musl is forbidden -- klippy dlopens a glibc
#     c_helper.so.
#
# THE CROSS TRICK. There is no crossenv here. The staged interpreter already
# carries _sysconfigdata__linux_mipsel-linux-gnu.py, which records the cross
# CC, LDSHARED, EXT_SUFFIX (.cpython-313-mipsel-linux-gnu.so) and INCLUDEPY
# (/usr/data/anvil/include/python3.13). Exporting _PYTHON_SYSCONFIGDATA_NAME
# at an x86-64 CPython 3.13 of the SAME version makes sysconfig -- and so
# setuptools' build_ext -- answer every question about the TARGET. The staged
# tree is bind-mounted at its real prefix so INCLUDEPY resolves without
# rewriting anything.
#
# WHAT IS BUILT AND WHY THAT LIST. Not moonraker-requirements.txt, which
# installs every optional component's dependency. The list is what the
# ENABLED component set imports -- assets/moonraker.conf's sections plus
# server.CORE_COMPONENTS, closed over moonraker's own imports (see
# scan-imports.py beside this file) -- plus what klippy needs.
#
# Usage:
#     ./build-pyext.sh              # in docker
#     ./build-pyext.sh --in-container
# ---------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PYBUILD="${PYBUILD:-$HERE/../pybuild}"
REPO="${REPO:-/home/shish/firmware/.claude/worktrees/s6-vs-runit}"
TOOLCHAIN_HOST="$REPO/work/.mips-toolchain/mips-gcc720-glibc229"

if [ "${1:-}" != "--in-container" ]; then
    [ -x "$TOOLCHAIN_HOST/bin/mips-linux-gnu-gcc" ] || {
        echo "!! no toolchain at $TOOLCHAIN_HOST" >&2; exit 1; }
    [ -x "$PYBUILD/hostpy/bin/python3.13" ] || {
        echo "!! no build-python at $PYBUILD/hostpy -- run tools/python/build.sh" >&2; exit 1; }
    [ -d "$PYBUILD/stage/usr/data/anvil/include/python3.13" ] || {
        echo "!! no UNTRIMMED stage at $PYBUILD/stage -- the shipped tree has no headers" >&2; exit 1; }
    exec docker run --rm \
        -v "$TOOLCHAIN_HOST":/toolchain:ro \
        -v "$PYBUILD":/work \
        -v "$PYBUILD/stage/usr/data/anvil":/usr/data/anvil:ro \
        -v "$HERE":/pyext \
        -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
        -e ONLY="${ONLY:-}" \
        -w /pyext debian:bookworm \
        bash /pyext/build-pyext.sh --in-container
fi

# ======================= everything below runs in the container =============
START=$(date +%s)
export DEBIAN_FRONTEND=noninteractive
TC=/toolchain
DEP=/work/deproot                 # the static C libraries CPython was built on
HOSTPY=/work/hostpy/bin/python3.13
P=/pyext
SRC=$P/src                        # sdist cache
WHEELS=$P/wheels                  # built wheels
SP=$P/site-packages               # the tree that would ship
LOGS=$P/logs
mkdir -p "$SRC" "$WHEELS" "$SP" "$LOGS"

log() { echo; echo "===== $* ====="; }

log "apt"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    build-essential curl ca-certificates pkg-config file xz-utils patch >/dev/null

# --------------------------------------------------------- the wrappers ----
# Identical to tools/python/build.sh. This is the single most important trick
# in either file.
log "toolchain wrappers (-EL -mnan=2008 baked in)"
mkdir -p /opt/xw/bin
for t in gcc g++ cpp; do
    cat > /opt/xw/bin/mips-linux-gnu-$t <<EOF
#!/bin/sh
exec $TC/bin/mips-linux-gnu-$t -EL -mnan=2008 "\$@"
EOF
    chmod +x /opt/xw/bin/mips-linux-gnu-$t
done
for t in ar as ld nm objcopy objdump ranlib readelf strip strings size; do
    ln -sf $TC/bin/mips-linux-gnu-$t /opt/xw/bin/mips-linux-gnu-$t
done
export PATH=/opt/xw/bin:$PATH

echo 'int main(void){return 0;}' > /tmp/abi.c
mips-linux-gnu-gcc /tmp/abi.c -o /tmp/abi.out
FLAGS=$(mips-linux-gnu-readelf -h /tmp/abi.out | awk '/Flags:/{print $2}' | tr -d ,)
echo "wrapper produces e_flags=$FLAGS"
[ "$FLAGS" = "0x70001405" ] || { echo "!! wrong ABI from the wrapper"; exit 1; }

# ------------------------------------------------------------ pip ----------
# The build-python was configured --without-ensurepip, so it has no pip. It is
# the SAME 3.13.7 the cross build used, which is what makes its sysconfig
# machinery interchangeable with the target's; a distro python3.11 is not.
if ! "$HOSTPY" -c 'import pip' 2>/dev/null; then
    log "bootstrap pip into the build-python"
    curl -sSLf -o /tmp/get-pip.py https://bootstrap.pypa.io/get-pip.py
    "$HOSTPY" /tmp/get-pip.py -q
fi
# Every package below is built from its SDIST with build isolation OFF, so
# every PEP 517 backend any of them names has to be here in advance. That is
# not a convenience: with isolation ON, pip rewrites PYTHONPATH for the build
# subprocess, the cross _sysconfigdata module stops being importable, and the
# build either dies ("No module named '_sysconfigdata__linux_mipsel-linux-gnu'")
# or -- worse -- silently answers every sysconfig question for x86-64.
"$HOSTPY" -m pip install -q --upgrade \
    'setuptools>=68' wheel 'cython<3.1' flit_core poetry-core hatchling \
    hatch-vcs setuptools-scm
"$HOSTPY" -VV

# -------------------------------------------------------- cross env --------
log "cross environment"
export _PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__linux_mipsel-linux-gnu
export PYTHONPATH=/usr/data/anvil/lib/python3.13
export PYTHONDONTWRITEBYTECODE=1
export CC=mips-linux-gnu-gcc
export CXX=mips-linux-gnu-g++
export AR=mips-linux-gnu-ar
export RANLIB=mips-linux-gnu-ranlib
export STRIP=mips-linux-gnu-strip
export LDSHARED="mips-linux-gnu-gcc -shared -L$DEP/lib"
export CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64 -I$DEP/include -I/usr/data/anvil/include/python3.13"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-L$DEP/lib"
# pkg-config must see ONLY the cross sysroot, never the container's /usr/lib.
export PKG_CONFIG_LIBDIR="$DEP/lib/pkgconfig"
export PKG_CONFIG_PATH="$DEP/lib/pkgconfig"

"$HOSTPY" - <<'PY'
import sysconfig
for k in ("EXT_SUFFIX", "SOABI", "INCLUDEPY", "CC", "LDSHARED"):
    print("  %-11s %s" % (k, sysconfig.get_config_var(k)))
assert sysconfig.get_config_var("EXT_SUFFIX") == ".cpython-313-mipsel-linux-gnu.so", \
    "sysconfig is answering for the HOST -- _PYTHON_SYSCONFIGDATA_NAME did not take"
PY

# ------------------------------------------------------------ helpers ------
want() { [ -z "${ONLY:-}" ] && return 0; case " $ONLY " in *" $1 "*) return 0;; *) return 1;; esac; }

# build <spec> [env=val ...]
#
# --no-binary :all: is not optional and not caution. Without it pip HELPFULLY
# downloads a prebuilt manylinux wheel and the "cross build" of cffi, greenlet
# and tornado silently becomes x86-64 -- measured, first run of this script:
# three x86-64 .so files sailed into the tree and only the ABI gate caught
# them. A wheel that is the wrong architecture is not a build failure anywhere
# except on the printer.
#
# --no-build-isolation is what keeps _PYTHON_SYSCONFIGDATA_NAME reaching
# setup.py; see the backend pre-install above.
build() {
    local spec=$1 name=${1%%[=<>]*}; shift
    want "$name" || return 0
    echo "-- $spec"
    if env "$@" "$HOSTPY" -m pip wheel --no-deps --no-build-isolation \
            --no-binary :all: -w "$WHEELS" "$spec" \
            >"$LOGS/$name.log" 2>&1; then
        echo "   ok"
    else
        echo "   !! FAILED -- $LOGS/$name.log"; tail -25 "$LOGS/$name.log"
        FAILED="$FAILED $name"
    fi
}

# sdist <url> <sha256> <dir-name>
#
# Two packages cannot come from `pip wheel <spec>`, for unrelated reasons, and
# both need their unpacked source anyway. Fetched by URL and CHECKED, the way
# versions.env pins everything else in this repo: the only thing between a
# source URL and code the printer executes is the hash.
sdist() {
    local url=$1 want=$2 dir=$3 f="$SRC/$(basename "$1")"
    [ -s "$f" ] || curl -sSLf -o "$f" "$url"
    local got
    got=$(sha256sum "$f" | cut -d" " -f1)
    [ "$got" = "$want" ] || { echo "!! $(basename "$f") sha256 $got, expected $want"; exit 1; }
    rm -rf "${SRC:?}/$dir"
    tar -xzf "$f" -C "$SRC"
    echo "$SRC/$dir"
}

# builddir <dir> [env=val ...]  -- wheel an already-unpacked source tree.
builddir() {
    local dir=$1 name; name=$(basename "$dir"); shift
    echo "-- $name (from source tree)"
    if env "$@" "$HOSTPY" -m pip wheel --no-deps --no-build-isolation \
            -w "$WHEELS" "$dir" >"$LOGS/$name.log" 2>&1; then
        echo "   ok"
    else
        echo "   !! FAILED -- $LOGS/$name.log"; tail -25 "$LOGS/$name.log"
        FAILED="$FAILED $name"
    fi
}

FAILED=""

# ============================================================ packages ======
# THE LIST IS NOT moonraker-requirements.txt. That file installs every
# optional component's dependency -- apprise, ldap3, paho-mqtt, zeroconf,
# python-periphery, smart_open, dbus-next's mqtt friends. None of those
# components is configured in assets/moonraker.conf, so none of them is built
# here. What IS built is the closure of what the ENABLED set imports
# (scan-imports.py), plus klippy's three.
log "packages"

# ---- pure python (no compiler is invoked; they are here to be PRESENT) ----
build "distro==1.9.0"
build "inotify-simple==1.3.5"
build "libnacl==2.1.0"
build "dbus-next==0.2.3"
# preprocess-cancellation 0.2.1's sdist declares version 0.0.0 in its own
# metadata -- a broken upstream release, not something about this target. pip
# refuses it ("has inconsistent version: expected '0.2.1', but metadata has
# '0.0.0'") for the specifier, so the tree is fetched by URL, hash-checked,
# and wheeled as a directory, where pip has no specifier to disagree with. It
# is a lazily-imported optional path inside the metadata SUBPROCESS
# (gcode object cancellation), so a printer without it loses that feature and
# nothing else.
if want preprocess-cancellation; then
    builddir "$(sdist \
        https://files.pythonhosted.org/packages/4a/56/7e18b0336c1e6c6622411dd0d3a7634b171e4d156a13b1ceaa048682454a/preprocess_cancellation-0.2.1.tar.gz \
        e2f1224e1ba1603bdfdbf6937caaf91082dc849e5122e80a5328aa999433ce79 \
        preprocess_cancellation-0.2.1)"
fi
build "pyserial==3.4"
build "pyserial-asyncio==0.6"
build "pycparser==2.22"          # cffi's only runtime dependency
# smart_open is not optional, whatever its name suggests, and it is not
# moonraker that wants it: streaming-form-data's targets.py imports it at
# module scope, so `import streaming_form_data` raises ModuleNotFoundError
# without it -- measured in the replica, where every other package imported
# and that one did not. moonraker-requirements.txt pins it (`smart_open<=6.4.0`)
# for exactly this reason. Pure python, no dependencies of its own.
build "smart_open==6.4.0"
build "jinja2==3.1.4"
# setuptools/pkg_resources are a dependency of nothing here. They are the fix
# for a measured failure: a trimmed tree without them made the lmdb egg fall
# back to its cffi path and try to invoke mips-linux-gnu-gcc ON THE PRINTER at
# Moonraker startup. There is no compiler on the printer.
build "setuptools==75.6.0"

# ---- native ---------------------------------------------------------------
# tornado's C speedup is optional and its published wheel carries an x86-64
# copy of it, so this builds from sdist like everything else and gets a mipsel
# one.
build "tornado==6.4.0"

# markupsafe -- jinja2's escape accelerator, on the path of every gcode macro
# klippy renders. Pure-python fallback exists (_native.py) if it ever fights.
build "markupsafe==2.1.5"

# cffi -- klippy's chelper. Wants libffi; deproot has a static -fPIC one and a
# .pc for it, and PKG_CONFIG_LIBDIR makes that the only one it can see.
build "cffi==1.17.1"

# greenlet -- klippy's reactor. Expected to fight over its hand-written
# stack-switching assembly (switch_mips_unix.h); fought over something else
# entirely, and the assembly was never the problem.
#
# greenlet 3.x is C++ and writes every PyTypeObject / PyNumberMethods as a
# DESIGNATED INITIALIZER. Those are C++20; gcc 7.2 -- the Ingenic toolchain,
# and the only compiler that produces this printer's ABI -- takes them as an
# extension but only in declaration order with no gaps, and refuses anything
# else with
#
#     sorry, unimplemented: non-trivial designated initializers not supported
#
# A PyTypeObject naming 20 of its 50 slots is nothing but gaps, so all three
# of greenlet's fail. fill-designators.py writes the skipped fields back as
# explicit zeros, reading the field ORDER out of the target interpreter's own
# headers rather than a list typed in here -- and refuses to guess if a
# designator turns up that the header does not have. These are objects of
# static storage duration, so every field it inserts was already zero; the
# patch changes the spelling, not the program.
if want greenlet; then
    GL=$(sdist https://files.pythonhosted.org/packages/2f/ff/df5fede753cc10f6a5be0931204ea30c35fa2f2ea7a35b25bdaf4fe40e46/greenlet-3.1.1.tar.gz \
        4ce3ac6cdb6adf7946475d7ef31777c26d94bccc377e070a7986bd2d5c515467 \
        greenlet-3.1.1)
    "$HOSTPY" /pyext/fill-designators.py /usr/data/anvil/include/python3.13 \
        $(find "$GL/src/greenlet" -name '*.cpp' -o -name '*.hpp' | sort)
    builddir "$GL"
fi

# lmdb -- moonraker's database AT THIS PIN, and the package that disappears
# the moment the pin moves past 80c7620 (lmdb -> sqlite), which is the whole
# point of having built an interpreter with _sqlite3.
#
# LMDB_FORCE_CPYTHON=1 is load-bearing. lmdb's setup.py has two backends: a
# real CPython extension and a cffi one that ships mdb.c and COMPILES IT AT
# IMPORT TIME. Left to itself here it chose cffi and produced a py3-none-any
# wheel containing mdb.c -- i.e. exactly the failure phase 6 already recorded,
# rebuilt from scratch. (Do not "fix" this with LMDB_FORCE_CFFI=0: the setup
# script tests the variable for PRESENCE, so the string "0" selects cffi.)
build "lmdb==1.4.1" LMDB_FORCE_CPYTHON=1

# streaming-form-data -- moonraker's upload parser, Cython. 1.13.0 (what
# moonraker-requirements.txt pins) ships a pregenerated _parser.c from a
# Cython that predates 3.13: it calls the four-argument _PyLong_AsByteArray,
# which grew a fifth parameter in 3.13, and every integer conversion in the
# file fails to compile. Regenerating from the .pyx with a current Cython is
# the fix, and a later release ships C that is already regenerated -- moonraker
# only asks five names of it (StreamingFormDataParser, ParseFailedException,
# FileTarget, ValueTarget, SHA256Target), all present throughout the 1.x line.
build "streaming-form-data==1.19.1"

# pillow -- Moonraker's ONLY use of it is
# components/file_manager/metadata.py, which runs as a SUBPROCESS to pull
# thumbnails out of gcode. So it is not on the startup path: without it
# Moonraker runs and Mainsail shows no thumbnails. It is built anyway because
# the cost turned out to be one flag list.
#
# ZLIB ONLY. Gcode thumbnails are base64 PNG, so zlib is the only codec on
# that path; jpeg, tiff, webp, jpeg2000, lcms, freetype and imagequant are
# libraries nobody has cross-built here and every one of them is off. Pillow
# probes for them by trying to LINK against the host's copies unless told not
# to, which is what --disable-platform-guessing is for.
#
# NOT 10.3.0, which is what moonraker-requirements.txt pins. That release
# cannot be built by python 3.13 AT ALL, and not for any reason to do with
# this target: its setup.py reads its own version with
#
#     exec(compile(open("src/PIL/_version.py").read(), ...))
#     return locals()["__version__"]
#
# and PEP 667 (new in 3.13) made a function's locals() a snapshot, so the
# name exec() defined is not there any more and setup.py dies with
# KeyError: '__version__' before it compiles a single file. 11.0.0 is the
# first line that supports 3.13. Moonraker asks PIL for Image.open, resize
# and save, all unchanged across that gap.
#
# pip cannot drive this: the disable flags are build_ext options and there is
# no PEP 517 path to them, so setup.py is called directly.
if want pillow; then
    PIL_SRC=$(sdist https://files.pythonhosted.org/packages/a5/26/0d95c04c868f6bdb0c447e3ee2de5564411845e36a858cfd63766bc7b563/pillow-11.0.0.tar.gz \
        72bacbaf24ac003fea9bff9837d1eedb6088758d41e100c1552930151f677739 \
        pillow-11.0.0)
    echo "-- pillow 11.0.0 (zlib only, setup.py direct)"
    if ( cd "$PIL_SRC" && "$HOSTPY" setup.py build_ext \
            --disable-jpeg --disable-tiff --disable-webp --disable-jpeg2000 \
            --disable-imagequant --disable-lcms --disable-freetype \
            --disable-xcb --disable-platform-guessing --enable-zlib \
            -I"$DEP/include" -L"$DEP/lib" bdist_wheel ) \
            >"$LOGS/pillow.log" 2>&1; then
        cp -a "$PIL_SRC"/dist/*.whl "$WHEELS/"
        echo "   ok"
    else
        echo "   !! FAILED -- $LOGS/pillow.log"; tail -25 "$LOGS/pillow.log"
        FAILED="$FAILED pillow"
    fi
fi

# =========================================================== assemble =======
log "wheels built"
ls -1 "$WHEELS" | sort

log "unpack into a site-packages tree"
rm -rf "$SP"; mkdir -p "$SP"
for w in "$WHEELS"/*.whl; do
    "$HOSTPY" -m zipfile -e "$w" "$SP"
done
find "$SP" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
find "$SP" -name '*.dist-info' -prune -exec rm -rf {} + 2>/dev/null || true
rm -rf "$SP"/bin "$SP"/*.data 2>/dev/null || true

# ============================================================= gates ========
# NO ABI GATE HERE. This used to walk every .so in the site-packages tree and pin e_flags per ELF
# type -- 0x70001405 for an EXEC, 0x70001407 for a DYN. It was one of five
# implementations of that rule and the strictest of them, strict enough to be
# wrong: the low three bits are NOREORDER/PIC/CPIC and vary between objects of
# identical ABI, so an exact-word compare refuses files the kernel loads
# happily. qa/replica/test_abi.py asks the question once, over the installed
# filesystem, masking those bits off.

echo
echo "-- NEEDED of each extension module (nothing may want a /usr/prog soname) --"
find "$SP" -name '*.so' | sort | while read -r f; do
    printf '%-58s %s\n' "${f#$SP/}" \
        "$(mips-linux-gnu-readelf -d "$f" | awk '/NEEDED/{gsub(/[][]/,"",$5); printf "%s ", $5}')"
done

log "strip and size"
find "$SP" -name '*.so' -exec mips-linux-gnu-strip {} + 2>/dev/null || true
du -sh "$SP"
echo "$(find "$SP" -type f | wc -l) files"
echo "-- top level --"
ls -1 "$SP"

log "tarball"
# Root is site-packages/ so a case script can drop it beside the interpreter's
# own lib/python3.13/site-packages.
tar -czf "$P/pyext.tgz" -C "$P" site-packages
ls -l "$P/pyext.tgz"

chown -R "${HOST_UID:-0}:${HOST_GID:-0}" "$P" 2>/dev/null || true

END=$(date +%s)
log "done in $(( (END-START)/60 ))m $(( (END-START)%60 ))s"
[ -z "$FAILED" ] && echo "all packages built" || { echo "!! FAILED:$FAILED"; exit 1; }
