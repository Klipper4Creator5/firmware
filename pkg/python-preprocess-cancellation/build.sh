#!/usr/bin/env bash
# preprocess_cancellation -- built for the printer's CPython, into its site-packages.
set -euo pipefail
. "$(dirname "$0")/../../bin/common.sh"
. pkg/lib.sh

pkg_begin python-preprocess-cancellation || exit 0
pkg_unpack "$(pypkg_tgz preprocess-cancellation)"

# COPIED, NOT BUILT. This sdist declares no [build-system] and ships no
# setup.py, so there is no backend to call -- pip's legacy fallback would
# auto-discover a flat layout and emit a wheel named UNKNOWN-0.0.0 containing
# the one module, which is the right file arrived at by an accident a future
# setuptools is free to change. The package IS one module, so the honest
# operation is a copy. (The same release also declares version 0.0.0 in its own
# metadata, so a version specifier would be refused by pip even if there were
# something to build.)
pkg_stage "$(pkg_pysrc preprocess-cancellation)/preprocess_cancellation.py" \
    "lib/python$PY_MM/site-packages/preprocess_cancellation.py"

pkg_ship "lib/python$PY_MM/site-packages"
pkg_end
