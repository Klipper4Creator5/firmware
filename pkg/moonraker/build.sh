#!/usr/bin/env bash
# Moonraker -- stage the pinned source tree into the prefix.
#
# GitHub's generated tarball wraps everything in moonraker-<sha>/, and the
# thing we want is the moonraker/ package directory inside it -- not the
# repository root, which also carries docs, scripts and a test suite. So the
# unpack keeps the wrapper and the stage reaches through it, rather than
# --strip-components hiding the shape of the archive from whoever reads this.
#
# WHAT IS REMOVED, AND WHY IT IS REMOVED HERE. tests/ is a sizeable part of the
# tree and never runs on a printer; __pycache__ directories are build
# droppings that would otherwise be shipped, be wrong for the interpreter that
# reads them, and make the package unreproducible for no benefit. Both were
# trimmed by bin/patch.sh before this recipe existed and are trimmed in the
# same place they always were -- once, on the way in.
set -euo pipefail
. "$(dirname "$0")/../../bin/common.sh"
. pkg/lib.sh

pkg_begin moonraker || exit 0
pkg_unpack "$MOONRAKER_TGZ"

_src="$PKG_WORK/src/moonraker-$MOONRAKER_VERSION/moonraker"
# The guard bin/patch.sh has always had, kept: a tarball whose shape changed
# under us would otherwise stage nothing, which looks like a clean build and a
# dead web UI.
[ -f "$_src/moonraker.py" ] || pkg_die \
    "moonraker: no moonraker/moonraker.py in $(basename "$MOONRAKER_TGZ")"

pkg_stage "$_src" "moonraker"
rm -rf "$PKG_WORK/stage$MODDIR/moonraker/tests"
find "$PKG_WORK/stage$MODDIR/moonraker" -name '__pycache__' -type d \
    -exec rm -rf {} + 2>/dev/null || true

pkg_ship "moonraker"
pkg_end
