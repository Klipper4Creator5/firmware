#!/usr/bin/env bash
# pyserial-asyncio -- built for the printer's CPython, into its site-packages.
set -euo pipefail
. "$(dirname "$0")/../../bin/common.sh"
. pkg/lib.sh

pkg_begin python-pyserial-asyncio || exit 0
pkg_toolchain
pkg_deps
pkg_buildpython
pkg_pytarget
pkg_unpack "$(pypkg_tgz pyserial-asyncio)"
pkg_pywheel pyserial-asyncio
pkg_ship "lib/python$PY_MM/site-packages"
pkg_end
