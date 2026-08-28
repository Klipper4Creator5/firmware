#!/usr/bin/env bash
# setuptools and pkg_resources. Nothing in this feed imports them at runtime; they are here so that lmdb never reaches for its compile-at-import fallback. -- built for the printer's CPython, into its site-packages.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin python-setuptools || exit 0
pkg_toolchain
pkg_deps
pkg_buildpython
pkg_pytarget
pkg_unpack "$(pypkg_tgz setuptools)"
pkg_pywheel setuptools
pkg_ship "lib/python$PY_MM/site-packages"
pkg_end
