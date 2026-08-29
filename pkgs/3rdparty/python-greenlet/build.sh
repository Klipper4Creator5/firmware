#!/usr/bin/env bash
# greenlet -- built for the printer's CPython, into its site-packages.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin python-greenlet || exit 0
pkg_toolchain
pkg_deps
pkg_buildpython
pkg_pytarget
pkg_unpack "$(pypkg_tgz greenlet)"

# gcc 7.2 refuses greenlet 3.x's C++ designated initializers wherever they skip
# a field. The rule was probed, not assumed: in-order contiguous is fine, a
# TRAILING gap is fine, an interior or leading gap is refused.
# fill-designators.py writes the skipped fields back as explicit zeros, taking
# field order from the TARGET's own headers and refusing to guess about a
# designator that is not in them. These are objects of static storage duration,
# so every field it inserts was already zero: it changes the spelling, not the
# program. 55 fields across two files.
_g=$(pkg_pysrc greenlet)
# Deliberately unquoted: the find is a LIST of sources to patch, one argument
# each, and none of greenlet's file names has ever contained a space.
# shellcheck disable=SC2046
"$HOSTPY" tools/python-packages/fill-designators.py \
    "$PKG_PYINC" \
    $(find "$_g/src/greenlet" -name '*.cpp' -o -name '*.hpp' | sort) \
    > "$PKG_LOG/fill-designators.log" 2>&1 \
    || pkg_die "greenlet: fill-designators.py failed -- see $PKG_WORK/fill-designators.log"

pkg_pywheel greenlet
pkg_ship "lib/python$PY_MM/site-packages"

# One is the whole package: greenlet IS _greenlet, and everything above this
# line exists because that C++ has to compile for this ABI. The default count
# rather than the three .so files actually shipped -- the other two are
# greenlet/tests/, which ride along and are nobody's dependency.
pkg_pynative
pkg_end
