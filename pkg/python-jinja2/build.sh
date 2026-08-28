#!/usr/bin/env bash
# Jinja2 -- built for the printer's CPython, into its site-packages.
set -euo pipefail
. "$(dirname "$0")/../../bin/common.sh"
. pkg/lib.sh

pkg_begin python-jinja2 || exit 0
pkg_toolchain
pkg_deps
pkg_buildpython
pkg_pytarget
pkg_unpack "$(pypkg_tgz jinja2)"
pkg_pywheel jinja2
pkg_ship "lib/python$PY_MM/site-packages"
pkg_end
