#!/usr/bin/env bash
# importlib_metadata -- built for the printer's CPython, into its
# site-packages.
#
# Its backend is setuptools_scm, which normally reads the version out of a git
# checkout. There is none here, and there does not need to be: an sdist
# carries PKG-INFO and setuptools_scm takes the version from it.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin python-importlib-metadata || exit 0
pkg_toolchain
pkg_deps
pkg_buildpython
pkg_pytarget
pkg_unpack "$(pypkg_tgz importlib-metadata)"
pkg_pywheel importlib-metadata
pkg_ship "lib/python$PY_MM/site-packages"
pkg_end
