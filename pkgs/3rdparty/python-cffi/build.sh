#!/usr/bin/env bash
# cffi -- built for the printer's CPython, into its site-packages.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin python-cffi || exit 0
pkg_toolchain
pkg_deps
pkg_buildpython
pkg_pytarget
pkg_unpack "$(pypkg_tgz cffi)"
pkg_pywheel cffi
pkg_ship "lib/python$PY_MM/site-packages"
pkg_end
