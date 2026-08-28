#!/usr/bin/env bash
# streaming_form_data -- built for the printer's CPython, into its site-packages.
set -euo pipefail
. "$(dirname "$0")/../../bin/common.sh"
. pkg/lib.sh

pkg_begin python-streaming-form-data || exit 0
pkg_toolchain
pkg_deps
pkg_buildpython
pkg_pytarget
pkg_unpack "$(pypkg_tgz streaming-form-data)"
pkg_pywheel streaming-form-data
pkg_ship "lib/python$PY_MM/site-packages"
pkg_end
