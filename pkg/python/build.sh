#!/usr/bin/env bash
# CPython, cross-compiled for the printer against the seven libraries this
# feed already builds.
#
# THE SEVEN LIBRARIES ARE STATIC AND NONE OF THEM SHIPS WITH THIS PACKAGE.
# They come out of the feed as -dev packages -- headers and .a files -- and are
# linked into the interpreter and its extension modules, so the tree on the
# printer has no .so of ours to find at runtime: no LD_LIBRARY_PATH to get
# right, no chance of picking up one of FlashForge's /usr/prog copies (a real
# hazard -- /usr/prog carries libffi.so.8 and the rootfs carries libffi.so.7),
# and nothing to version-skew. The cost is a few MB of duplicated libcrypto
# between _ssl.so and _hashlib.so, which is a good trade at 30MB.
set -euo pipefail
. "$(dirname "$0")/../../bin/common.sh"
. pkg/lib.sh

pkg_begin python || exit 0
pkg_toolchain
pkg_deps
pkg_buildpython
pkg_unpack "$PY_TGZ"

_sys="$PKG_SYSROOT$MODDIR"

# Answers to the questions configure settles by COMPILING AND RUNNING a probe,
# which it cannot do when the target is mipsel and the builder is x86. Left
# unanswered these either stop configure or -- worse -- default to the
# conservative answer and produce a working interpreter with subtly wrong float
# and time behaviour.
cat > "$PKG_WORK/src/config.site" <<'EOF'
ac_cv_file__dev_ptmx=yes
ac_cv_file__dev_ptc=no
ac_cv_buggy_getaddrinfo=no
ac_cv_little_endian_double=yes
ac_cv_big_endian_double=no
ac_cv_mixed_endian_double=no
ac_cv_working_tzset=yes
ac_cv_have_long_long_format=yes
ac_cv_no_strict_aliasing=no
ac_cv_pthread_system_supported=yes
EOF
export CONFIG_SITE="$PWD/$PKG_WORK/src/config.site"
export CFLAGS="-O2 -D_FILE_OFFSET_BITS=64"

# THE TRAP THAT COSTS A DAY IF YOU MISS IT, and the reason the gates at the
# bottom of this file exist:
#   -latomic  64-bit atomics on mips32 are out-of-line calls into libatomic,
#             and CPython 3.13's _Py_atomic_* on 64-bit types needs them.
#             libatomic.so.1 IS on the printer's rootfs -- measured -- so this
#             one is a runtime dependency, not a static link.
#   -lm       because libsqlite3 here is STATIC. A shared libsqlite3.so carries
#             its own DT_NEEDED on libm; a libsqlite3.a does not. configure's
#             `checking for sqlite3_bind_double in -lsqlite3` link probe then
#             fails on undefined floor/log/pow, and CPython records _sqlite3 as
#             "missing" AND CARRIES ON -- a probe failure, not a compile
#             failure, so nothing in 400 lines of build output says why the one
#             module this whole package exists for is absent.
export LIBS="-latomic -lm"
# And the same link line stated outright, bypassing pkg-config, so that -lm
# cannot be reordered out from under the probe.
export LIBSQLITE3_CFLAGS="-I$_sys/include"
export LIBSQLITE3_LIBS="-L$_sys/lib -lsqlite3 -lm"

# --disable-shared: no libpython3.13.so to find at runtime, for the same reason
#   the seven libraries are static. Extension modules resolve their Python
#   symbols out of the interpreter's own dynamic symbol table, which CPython
#   links with -export-dynamic precisely so that they can.
# --without-ensurepip: pip needs a network and a compiler; neither is on a
#   printer, and a pip that half works is worse than none. The BUILD-python has
#   the opposite answer for the opposite reason -- see pkg_buildpython.
# --disable-test-modules: the CPython test suite is a third of the tree and
#   none of it runs here.
pkg_build "Python-$PY_VERSION" \
    --build=x86_64-linux-gnu \
    --with-build-python="$HOSTPY" \
    --disable-shared \
    --without-ensurepip \
    --disable-test-modules \
    --with-openssl="$_sys" \
    --with-system-expat

# ------------------------------------------------------------------ the trim
#
# What goes, and none of it is fussiness: idlelib and turtledemo (nothing on a
# printer runs either), tkinter (there is no X11), share/ (man pages), every
# __pycache__ -- which is 12MB of .pyc for modules that will be imported once,
# if ever, and which the interpreter regenerates into /usr/data anyway if it
# ever wants them -- and libpython3.13.a, 35MB of static archive that exists to
# link a python that is not this one.
#
# It is done HERE rather than by PKG_EXCLUDE because these are paths, not
# names: PKG_EXCLUDE is a `find -name` sweep, and `-name test` over a CPython
# tree removes a dozen legitimate submodules along with the one directory
# meant.
_st="$PKG_WORK/stage$MODDIR"
rm -rf "$_st/lib/python$PY_MM/idlelib" \
       "$_st/lib/python$PY_MM/tkinter" \
       "$_st/lib/python$PY_MM/turtledemo" \
       "$_st/share"
rm -f "$_st/lib/libpython$PY_MM.a" \
      "$_st/lib/python$PY_MM/config-$PY_MM-"*/"libpython$PY_MM.a"
find "$_st" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

# ------------------------------------------------------------------ the ship
#
# ONE BINARY OUT OF bin/, BY NAME. `make install` also leaves python3, idle3,
# pydoc3, python3-config and python3.13-config there; naming what ships is what
# keeps bin/python3 -- which would shadow FlashForge's interpreter on the PATH
# anvil-env.sh exports -- from ever reaching a printer. It is a stronger rule
# than the `rm` bin/patch.sh used to do, because a future CPython that installs
# one more launcher is silently excluded rather than silently included.
#
# site-packages rides along inside lib/python3.13/ and needs no line of its
# own: `make install` creates it empty, this package owns it, and the eighteen
# pkg/python-* packages drop their files into it.
pkg_ship "bin/python$PY_MM" "lib/python$PY_MM" "include" "lib/pkgconfig"

# ----------------------------------------------------------------- the gates
#
# ONE PER BUILD DEPENDENCY, ASKED BY MODULE NAME. CPython does not fail when it
# cannot link a library: configure records the module as unavailable, `make`
# prints a line among four hundred others, and the install succeeds. So every
# one of the seven libraries in PKG_BUILD_DEPENDS is checked here by the module
# it was added for. Without this the failure mode is a package that installs
# cleanly and raises ImportError on a printer.
_dyn="$PKG_OUT/lib/python$PY_MM/lib-dynload"
for _m in _ssl _hashlib _sqlite3 zlib _ctypes _lzma _bz2 pyexpat; do
    ls "$_dyn/$_m".*.so >/dev/null 2>&1 \
        || pkg_die "python: NO $_m MODULE. Its library link probe failed silently -- see $PKG_WORK/Python-$PY_VERSION-configure.log"
done
[ -x "$PKG_OUT/bin/python$PY_MM" ] \
    || pkg_die "python: no bin/python$PY_MM came out of the install"

pkg_say "python: $(ls "$_dyn" | wc -l) stdlib extension modules, $(du -sh "$PKG_OUT/lib/python$PY_MM" | cut -f1) of library"
pkg_end
