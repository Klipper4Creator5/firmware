#!/usr/bin/env bash
# busybox -- the richer applet set, out of a binary this build did not compile.
#
# THE ONLY RECIPE WHOSE SOURCE IS NEITHER A PINNED TARBALL NOR THIS CHECKOUT.
# BUSYBOX_BIN names a busybox someone built elsewhere, and nothing needs it to
# be built here: the printer's own busybox works, and this one is a
# convenience for the applets FlashForge left out.
#
# WHY IT IS A PACKAGE AT ALL. It used to be a `cp` in bin/payload.sh, and it was
# the ONE file in the payload that no package owned -- which cost an allowance
# in the "every file is owned" test, an ABI gate of its own because the
# payload-wide one ran before the copy, and a file no `apk del` could
# take away.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin busybox || exit 0
pkg_prebuilt "$BUSYBOX_BIN"

# Staged rather than copied to $PKG_OUT directly, so pkg_ship's strip and
# archive normalisation see it like any other ELF object. It is already
# stripped in practice; going through the same path means it is stripped in
# principle.
pkg_stage "$BUSYBOX_BIN" "bin/busybox"
chmod +x "$PKG_WORK/stage$MODDIR/bin/busybox"
pkg_ship "bin/busybox"

# BUSYBOX_BIN is a path a user typed, so a foreign binary here is the
# likeliest ABI mistake in the feed. It is not checked at build time: the one
# ABI gate reads the installed filesystem in qa/replica/test_abi.py, which
# names this file if it is wrong.

pkg_say "busybox: $(du -h "$PKG_OUT/bin/busybox" | cut -f1) from BUSYBOX_BIN"
pkg_end
