#!/usr/bin/env bash
# lmdb -- built for the printer's CPython, into its site-packages.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin python-lmdb || exit 0
pkg_toolchain
pkg_deps
pkg_buildpython
pkg_pytarget
pkg_unpack "$(pypkg_tgz lmdb)"

# LMDB_FORCE_CPYTHON=1 IS LOAD-BEARING. lmdb's setup.py has two backends: a
# real CPython extension and a cffi one that ships mdb.c and COMPILES IT AT
# IMPORT TIME. Left to itself here it picks cffi and produces a py3-none-any
# wheel with mdb.c inside -- i.e. a Moonraker that tries to invoke a compiler
# on a printer that has none. Do not "fix" this with LMDB_FORCE_CFFI=0:
# setup.py tests the variable for PRESENCE, so the string "0" selects cffi.
pkg_pywheel lmdb LMDB_FORCE_CPYTHON=1

pkg_ship "lib/python$PY_MM/site-packages"
pkg_end
