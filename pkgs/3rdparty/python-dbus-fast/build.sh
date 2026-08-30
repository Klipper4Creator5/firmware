#!/usr/bin/env bash
# dbus_fast -- built for the printer's CPython, into its site-packages.
#
# SKIP_CYTHON=1 is read by the sdist's build_ext.py, which returns before it
# imports Cython. That is the supported way to ask for the pure-python build,
# and it is also the only one available here: pkg_pywheel builds with
# --no-build-isolation, so Cython is not in the build-python to import.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin python-dbus-fast || exit 0
pkg_toolchain
pkg_deps
pkg_buildpython
pkg_pytarget
pkg_unpack "$(pypkg_tgz dbus-fast)"
pkg_pywheel dbus-fast SKIP_CYTHON=1
pkg_ship "lib/python$PY_MM/site-packages"
pkg_end
