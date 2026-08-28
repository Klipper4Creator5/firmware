#!/usr/bin/env bash
# Pillow with zlib and nothing else -- built for the printer's CPython, into its site-packages.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin python-pillow || exit 0
pkg_toolchain
pkg_deps
pkg_buildpython
pkg_pytarget
pkg_unpack "$(pypkg_tgz pillow)"

# PIP CANNOT DRIVE THIS ONE: the --disable-* flags are build_ext options and
# PEP 517 offers no way to pass them, so PKG_PY_SETUP_ARGS calls setup.py
# directly. --disable-platform-guessing is the important one -- without it
# pillow probes for jpeg, tiff and the rest by trying to LINK against the build
# machine's copies.
PKG_PY_SETUP_ARGS="--disable-jpeg --disable-tiff --disable-webp
    --disable-jpeg2000 --disable-imagequant --disable-lcms --disable-freetype
    --disable-xcb --disable-platform-guessing --enable-zlib
    -I$PKG_SYSROOT$MODDIR/include -L$PKG_SYSROOT$MODDIR/lib"
pkg_pywheel pillow

pkg_ship "lib/python$PY_MM/site-packages"
pkg_end
