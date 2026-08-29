#!/usr/bin/env bash
# busybox -- the richer applet set, out of a binary this build did not compile.
#
# THE ONLY RECIPE WHOSE SOURCE IS NEITHER A PINNED TARBALL NOR THIS CHECKOUT.
# BUSYBOX_BIN in config.env names a busybox someone built elsewhere, and the
# reason it is not built here is that nothing needs it to be: the printer's
# own busybox works, this one is a convenience for the applets FlashForge left
# out. A recipe that cross-compiled busybox would be a real dependency on a
# real toolchain for a file that is optional by design.
#
# WHY IT IS A PACKAGE AT ALL. It used to be a `cp` in bin/patch.sh, and it was
# the ONE file in the payload that no package owned -- which cost three
# separate things: an allowance in qa/static/test_ipk.py's "every file is
# owned" test, an ABI gate of its own in patch.sh because the payload-wide one
# ran before the copy, and a file that .install-manifest listed but no
# `opkg remove` could take away. As a package it is none of those; it is
# absent or installed, like everything else.
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

# NAMED, THOUGH bin/build-packages.sh WOULD CATCH IT ANYWAY. Its gate says
# "this package has a foreign object in it"; this one can say which knob to
# turn, because this is the only recipe whose input is a path a user typed.
mips_abi_gate "$PKG_OUT/bin/busybox" >/dev/null || pkg_die \
    "BUSYBOX_BIN=$BUSYBOX_BIN is not nan2008/o32/mips32r2. The printer cannot
     exec it -- unset BUSYBOX_BIN in config.env, or point it at one built for
     this ABI"

pkg_say "busybox: $(du -h "$PKG_OUT/bin/busybox" | cut -f1) from BUSYBOX_BIN"
pkg_end
