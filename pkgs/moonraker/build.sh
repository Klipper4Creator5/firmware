#!/usr/bin/env bash
# Moonraker -- stage the pinned source tree into the prefix.
#
# GitHub's generated tarball wraps everything in moonraker-<sha>/, and the
# thing we want is the moonraker/ package directory inside it -- not the
# repository root, which also carries docs, scripts and a test suite. So the
# unpack keeps the wrapper and the stage reaches through it, rather than
# --strip-components hiding the shape of the archive from whoever reads this.
#
# WHAT IS REMOVED, AND WHY IT IS REMOVED HERE. tests/ is a sizeable part of
# the tree and never runs on a printer. It was trimmed by bin/patch.sh before
# this recipe existed and is trimmed in the same place it always was -- once,
# on the way in. The __pycache__ sweep that stood beside it is pkg_ship's
# now: it was written here and in pkgs/klipper and missing from anvil-core,
# which is the recipe that was actually shipping bytecode.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

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

pkg_ship "moonraker"
pkg_end
