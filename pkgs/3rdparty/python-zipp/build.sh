#!/usr/bin/env bash
# zipp -- built for the printer's CPython, into its site-packages.
#
# setuptools_scm is its backend; see python-importlib-metadata/build.sh for
# why that needs no git checkout.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin python-zipp || exit 0
pkg_toolchain
pkg_deps
pkg_buildpython
pkg_pytarget
pkg_unpack "$(pypkg_tgz zipp)"
pkg_pywheel zipp
pkg_ship "lib/python$PY_MM/site-packages"
pkg_end
