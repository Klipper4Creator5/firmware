#!/usr/bin/env bash
# anvil-klipper-config -- ff-*.cfg, staged out of this checkout.
#
# There is no build and no download: payload/config/ IS the package, laid out
# as it installs. See pkgs/klipper-config/pkg.conf for why these are not part
# of pkgs/klipper.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin klipper-config || exit 0
pkg_intree

pkg_stage "$PKG_DIR/payload/config" "config"

# A recipe that ships an empty directory is a recipe whose glob stopped
# matching. pkg_ship would catch "config" vanishing entirely; this catches it
# arriving empty, which is the shape a bad `git mv` leaves behind.
_n=$(find "$PKG_WORK/stage$MODDIR/config" -name 'ff-*.cfg' | wc -l)
[ "$_n" -gt 0 ] || pkg_die "klipper-config: no ff-*.cfg under $PKG_DIR/payload/config"

# printer.base.cfg is the hub every other config hangs off -- it includes the
# stock printer.*.cfg, the chamber config and the ff-*.cfg -- so a package
# without it installs a set that includes nothing.
[ -f "$PKG_WORK/stage$MODDIR/config/printer.base.cfg" ] || pkg_die \
    "klipper-config: no printer.base.cfg under $PKG_DIR/payload/config"

# BOTH CHAMBER CONFIGS, one per model. Named by machine rather than both
# called printer.chamber.cfg, so one package can carry them; anvil-link-prog.sh
# symlinks whichever the printer names into place.
for _m in Creator5 Creator5Pro; do
    [ -f "$PKG_WORK/stage$MODDIR/config/chamber/$_m.cfg" ] || pkg_die \
        "klipper-config: no chamber/$_m.cfg -- anvil-link-prog.sh resolves this name from app_startup.sh"
done

pkg_ship "config"
pkg_end
