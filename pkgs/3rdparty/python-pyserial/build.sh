#!/usr/bin/env bash
# pyserial -- built for the printer's CPython, into its site-packages.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin python-pyserial || exit 0
pkg_toolchain
pkg_deps
pkg_buildpython
pkg_pytarget
pkg_unpack "$(pypkg_tgz pyserial)"
pkg_pywheel pyserial
pkg_ship "lib/python$PY_MM/site-packages"
pkg_end
