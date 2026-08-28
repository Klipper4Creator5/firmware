#!/usr/bin/env bash
# sqlite -- cross-compiled for the printer, as a build dependency of CPython.
#
# THE REASON THE INTERPRETER EXISTS. FlashForge built python 3.8.2 without _sqlite3 and shipped no libsqlite3 anywhere on the image, so every Moonraker from v0.9.0 on -- the release that moved the database from lmdb to sqlite -- dies at startup with ModuleNotFoundError. This library is what closes that.
#
# NOTHING INSTALLS THIS ON A PRINTER. It is a static library: it ends up inside
# the interpreter, and there is no .so to ship or to find. The package exists
# so that CPython builds against something with a version and a checksum
# instead of against a directory somebody filled in earlier.
set -euo pipefail
. "$(dirname "$0")/../../bin/common.sh"
. pkg/lib.sh

pkg_begin sqlite || exit 0
pkg_toolchain
pkg_unpack "$SQLITE_TGZ"

# -fPIC because these are linked into extension modules, which are shared
# objects; -D_FILE_OFFSET_BITS=64 for the reason every cross-build in this tree
# carries it (32-bit build, 64-bit inodes -- see versions.env).
pkg_build "sqlite-autoconf-$SQLITE_VERSION" \
    --build="$(uname -m)-linux-gnu" \
    --disable-shared --enable-static --with-pic \
    --disable-readline --disable-editline \
    CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64"

pkg_ship "include/sqlite3.h" "include/sqlite3ext.h" "lib/libsqlite3.a" "lib/pkgconfig/sqlite3.pc"
pkg_end
