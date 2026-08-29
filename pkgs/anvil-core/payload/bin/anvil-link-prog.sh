#!/bin/sh
# Point the stock paths at the files the packages own.
#
# Everything the mod installs lives in $MODDIR. What the printer READS is
# elsewhere, at absolute paths FlashForge's scripts and Klipper's config
# choose and we do not: app_startup.sh runs
# /usr/prog/PROGRAM/software/firmwareExe, klipperDaemon is started from
# /usr/prog/klipper/start.sh, and printer.cfg includes its siblings out of
# /usr/data/config. This is the seam -- one symlink per file, so $MODDIR stays
# the only place anything is installed and `opkg upgrade` is enough to change
# what the printer runs.
#
# ORDERING. Stock run.sh distributes the software component at its lines
# 107-179, before run-append.sh extracts the payload at line 180. So the
# component cannot ship these symlinks itself: on a first install they would
# dangle, and on an upgrade they would resolve to the payload being replaced.
# This runs after extraction, and again from anvil-core's postinst. The
# component no longer carries firmwareExe or start.sh at all -- nothing execs
# either before this point, and a wrapper without a payload behind it is worse
# than no wrapper (app_startup.sh restores the stock binary from a version
# directory; the wrapper would just sit there and never start a UI).
set -e

MODDIR=${MODDIR:-/usr/data/anvil}

# Only on a machine that has the paths below. The build installs this package
# with opkg too, and opkg runs maintainer scripts with IPKG_INSTROOT empty --
# absolute paths are taken as written, not rebased -- so without this the
# postinst would act on whatever ran the build.
if [ ! -f /usr/prog/app_startup.sh ]; then
    echo "link-prog: not a printer (no /usr/prog/app_startup.sh) -- nothing to do"
    exit 0
fi

# $1 is relative to $MODDIR, $2 is the absolute path the printer reads. The
# two destinations under /usr/prog are the ones stock run.sh copies to, so this
# stays true as long as that does -- its two cp lines are no-ops now that the
# component ships neither file:
#     cp $WORK_DIR/firmwareExe /usr/prog/PROGRAM/software/
#     cp $WORK_DIR/start.sh    /usr/prog/klipper/start.sh
link_one() {
    src="$MODDIR/$1"
    dst="$2"

    [ -f "$src" ] || { echo "link-prog: no $src -- leaving $dst alone"; return 0; }

    # Already right: change nothing, so a re-run is quiet and cheap.
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
        return 0
    fi

    mkdir -p "$(dirname "$dst")"
    # Via a temp name: replacing the file app_startup.sh is about to execute
    # is not something to do non-atomically. The rm is because `ln -sf` onto
    # an existing symlink-to-directory links INSIDE it rather than replacing.
    rm -f "$dst.anvil-new"
    ln -s "$src" "$dst.anvil-new"
    mv -f "$dst.anvil-new" "$dst"
    echo "link-prog: $dst -> $src"
}

link_one prog/firmwareExe /usr/prog/PROGRAM/software/firmwareExe
link_one prog/start.sh    /usr/prog/klipper/start.sh

# The configs land in /usr/data/config because that is where printer.cfg is,
# and Klipper resolves [include] against the directory of the file doing the
# including -- configfile.py: `dirname = os.path.dirname(source_filename)`,
# the path as opened, NOT the resolved target. So a symlinked printer.base.cfg
# still finds the stock printer.filament.cfg and friends beside it, which is
# what lets those stay stock and unpackaged.
for _f in "$MODDIR"/config/ff-*.cfg; do
    [ -f "$_f" ] || continue
    link_one "config/$(basename "$_f")" "/usr/data/config/$(basename "$_f")"
done
link_one config/printer.base.cfg /usr/data/config/printer.base.cfg

# THE PRINTER SAYS WHICH MODEL IT IS, so nothing ships a marker: app_startup.sh
# is FlashForge's own and carries MACHINE= at its top. It is restored by any
# stock flash, so it stays right even when the payload is wrong.
MACHINE=$(sed -n 's/^MACHINE=//p' /usr/prog/app_startup.sh 2>/dev/null | head -1)
case "$MACHINE" in
    Creator5|Creator5Pro)
        link_one "config/chamber/$MACHINE.cfg" /usr/data/config/printer.chamber.cfg ;;
    *)
        # Not fatal: printer.base.cfg includes printer.chamber.cfg
        # unconditionally, so leaving what is there beats replacing it with a
        # guess. Klipper reports a missing include, which is a better failure
        # than the wrong chamber geometry.
        echo "link-prog: !! MACHINE='$MACHINE' is not a model I ship a chamber config for" >&2
        echo "link-prog:    leaving /usr/data/config/printer.chamber.cfg as it is" >&2 ;;
esac

exit 0
