#!/usr/bin/env bash
# execline -- cross-compiled against the packaged skalibs.
#
# --enable-absolute-paths IS THE ONE FLAG HERE WORTH EXPLAINING. Without it
# execline's EXTBINPREFIX is empty, which means a generated script that says
# `fdmove` resolves it through PATH. On this printer the PATH a service
# inherits comes from firmwareExe by way of s6-svscan, and a supervisor whose
# scripts depend on an inherited environment fails with "unable to exec
# fdmove" -- a message that names a program rather than the environment that
# was actually wrong. With the flag, generated scripts carry
# $MODDIR/bin/fdmove and depend on nothing.
#
# --with-sysdeps, --with-include and --with-lib all point INTO THE SYSROOT
# pkg_deps filled from anvil-skalibs.ipk. One of each is enough even when a
# recipe depends on three packages, because pkg_deps merges them all under one
# $MODDIR inside the sysroot -- the same layout they will have on the printer.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin execline || exit 0
pkg_toolchain
pkg_deps
pkg_unpack "$EXECLINE_TGZ"

_sr="$PKG_SYSROOT$MODDIR"
pkg_build "execline-$EXECLINE_VERSION" \
    --with-sysdeps="$_sr/lib/skalibs/sysdeps" \
    --with-include="$_sr/include" \
    --with-lib="$_sr/lib" \
    --enable-absolute-paths \
    --disable-shared --enable-static \
    CFLAGS="-Os -D_FILE_OFFSET_BITS=64"

# Executables, so strip-all rather than the --strip-unneeded that keeps a
# shared library's dynamic symbols. Nothing dlsyms an execline binary.
PKG_STRIP_ARGS=""

# The headers and the archive ship too, and not as an oversight: s6 and s6-rc
# link against libexecline, so this package is a build dependency as well as a
# runtime one. Shipping both from one package is what keeps "the thing my
# dependents build against is the thing the printer runs" true by construction.
pkg_ship "bin" "include/execline" "lib/libexecline.a"

# execlineb is the interpreter every generated script names in its shebang. If
# the ship list ever stops producing it, the failure is a printer that boots
# with no services and a message from the kernel about a missing interpreter.
[ -x "$PKG_OUT/bin/execlineb" ] || pkg_die \
    "execline: no bin/execlineb -- every s6-rc generated script starts with it"

pkg_end
