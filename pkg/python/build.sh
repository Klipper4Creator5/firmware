#!/usr/bin/env bash
# CPython, cross-compiled for the printer against the seven libraries this
# feed already builds.
#
# THE SEVEN LIBRARIES ARE STATIC AND NONE OF THEM SHIPS WITH THIS PACKAGE.
# They arrive as -dev packages -- headers and .a files -- and link into the
# interpreter and its extension modules, so the printer has no .so of ours to
# find at runtime: no LD_LIBRARY_PATH to get right and no chance of picking up
# one of FlashForge's /usr/prog copies (/usr/prog carries libffi.so.8 while the
# rootfs carries libffi.so.7). The cost is a few MB of libcrypto duplicated
# between _ssl.so and _hashlib.so.
set -euo pipefail
. "$(dirname "$0")/../../bin/common.sh"
. pkg/lib.sh

pkg_begin python || exit 0
pkg_toolchain
pkg_deps
pkg_buildpython
pkg_unpack "$PY_TGZ"

_sys="$PKG_SYSROOT$MODDIR"

# Answers to the questions configure settles by compiling and RUNNING a probe,
# which it cannot do when the target is mipsel and the builder is x86. Left
# unanswered they either stop configure or default to the conservative answer,
# producing a working interpreter with subtly wrong float and time behaviour.
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

# Both of these are why the gates at the bottom of this file exist:
#   -latomic  64-bit atomics on mips32 are out-of-line calls into libatomic,
#             which CPython 3.13's _Py_atomic_* on 64-bit types needs.
#             libatomic.so.1 is on the printer's rootfs, so this is a runtime
#             dependency, not a static link.
#   -lm       because libsqlite3 here is STATIC. A shared libsqlite3.so carries
#             its own DT_NEEDED on libm; a libsqlite3.a does not. configure's
#             `checking for sqlite3_bind_double in -lsqlite3` probe then fails
#             on undefined floor/log/pow, and CPython records _sqlite3 as
#             missing and carries on -- a probe failure, not a compile failure,
#             so nothing in the build output says why it is absent.
export LIBS="-latomic -lm"
# And the same link line stated outright, bypassing pkg-config, so that -lm
# cannot be reordered out from under the probe.
export LIBSQLITE3_CFLAGS="-I$_sys/include"
export LIBSQLITE3_LIBS="-L$_sys/lib -lsqlite3 -lm"

# --disable-shared: no libpython3.13.so to find at runtime, for the same reason
#   the seven libraries are static. Extension modules resolve their Python
#   symbols out of the interpreter's own dynamic symbol table, which CPython
#   links with -export-dynamic precisely so that they can.
# --without-ensurepip: pip needs a network and a compiler, and a printer has
#   neither. The build-python has the opposite answer; see pkg_buildpython.
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
# idlelib and turtledemo (nothing here runs either), tkinter (there is no
# X11), share/ (man pages), every __pycache__ (12MB of .pyc the interpreter
# regenerates into /usr/data if it ever wants them) and libpython3.13.a (35MB
# of archive that exists to link a python that is not this one).
#
# Done here rather than by PKG_EXCLUDE because these are paths, not names:
# PKG_EXCLUDE is a `find -name` sweep, and `-name test` over a CPython tree
# takes a dozen legitimate submodules with it.
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
# pydoc3, python3-config and python3.13-config there, and naming what ships is
# what keeps bin/python3 -- which would shadow FlashForge's interpreter on the
# PATH anvil-env.sh exports -- off a printer. Naming rather than removing means
# a future CPython that installs one more launcher is excluded by default.
#
# site-packages rides along inside lib/python3.13/ and needs no line of its
# own: `make install` creates it empty, this package owns it, and the
# pkg/python-* packages drop their files into it.
pkg_ship "bin/python$PY_MM" "lib/python$PY_MM" "include" "lib/pkgconfig"

# ----------------------------------------------------------------- the gates
#
# ONE PER BUILD DEPENDENCY, ASKED BY MODULE NAME. CPython does not fail when it
# cannot link a library: configure records the module as unavailable, make
# prints one line among hundreds, and the install succeeds. Without this the
# failure mode is a package that installs cleanly and raises ImportError on a
# printer.
_dyn="$PKG_OUT/lib/python$PY_MM/lib-dynload"
for _m in _ssl _hashlib _sqlite3 zlib _ctypes _lzma _bz2 pyexpat; do
    ls "$_dyn/$_m".*.so >/dev/null 2>&1 \
        || pkg_die "python: NO $_m MODULE. Its library link probe failed silently -- see $PKG_WORK/Python-$PY_VERSION-configure.log"
done
[ -x "$PKG_OUT/bin/python$PY_MM" ] \
    || pkg_die "python: no bin/python$PY_MM came out of the install"

pkg_say "python: $(ls "$_dyn" | wc -l) stdlib extension modules, $(du -sh "$PKG_OUT/lib/python$PY_MM" | cut -f1) of library"
pkg_end
