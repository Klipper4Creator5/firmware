#!/usr/bin/env bash
# inotify_simple -- built for the printer's CPython, into its site-packages.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin python-inotify-simple || exit 0
pkg_toolchain
pkg_deps
pkg_buildpython
pkg_pytarget
pkg_unpack "$(pypkg_tgz inotify-simple)"
pkg_pywheel inotify-simple
pkg_ship "lib/python$PY_MM/site-packages"
pkg_end
