#!/usr/bin/env bash
# anvil-klipper-creator5-config -- one .cfg, staged out of this checkout.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin klipper-creator5-config || exit 0
pkg_intree

pkg_stage "$PKG_DIR/payload/config" "config"
[ -f "$PKG_WORK/stage$MODDIR/config/printer.chamber.cfg" ] || pkg_die \
    "klipper-creator5-config: no printer.chamber.cfg under $PKG_DIR/payload/config"

pkg_ship "config"
pkg_end
