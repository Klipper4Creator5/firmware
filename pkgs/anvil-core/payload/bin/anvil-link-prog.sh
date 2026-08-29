#!/bin/sh
# Point the stock paths at the files the packages own.
#
# Everything the mod installs lives in $MODDIR. What the printer READS is
# elsewhere, at absolute paths FlashForge's scripts and Klipper's config
# choose and we do not: app_startup.sh runs
# /usr/prog/PROGRAM/software/firmwareExe, klipperDaemon is started from
# /usr/prog/klipper/start.sh, and printer.cfg includes its siblings out of
# /usr/data/config. This script is the seam between the two -- one symlink per
# file, so $MODDIR stays the only place anything is installed.
#
# They still arrive the stock way -- the software component carries them and
# run.sh copies them into place, which is what keeps a printer bootable when
# the mod payload is not there. This script runs afterwards and replaces those
# copies with symlinks into $MODDIR, so that from then on the file the printer
# executes is the one the package owns.
#
# WHY THAT IS WORTH DOING: without it, `opkg upgrade anvil-core` on a running
# printer updates $MODDIR and changes nothing the boot path reads -- the new
# firmwareExe sits in the payload while the old copy keeps being run, and the
# only way to land it is a full .tgz. With the links in place an opkg upgrade
# is enough, which is why the postinst calls this too.
#
# ORDERING IS THE WHOLE TRICK. Stock run.sh distributes the component at its
# lines 107-179, and run-append.sh does not extract anvil.tar.xz until line
# 180 -- so the component itself cannot ship symlinks: on a first install they
# would dangle, and on an upgrade they would resolve to the PREVIOUS payload
# and silently install the last release's files. Linking after extraction has
# neither problem.
set -e

MODDIR=${MODDIR:-/usr/data/anvil}

# The guard, and it is not optional. bin/patch.sh installs this package with a
# HOST opkg under --offline-root --force-postinstall, and that combination DOES
# execute maintainer scripts, with IPKG_INSTROOT empty -- so the paths below
# are taken as written rather than rebased onto the offline root. At build
# time that is inside the docker build image, which has no /usr/prog at all
# (make runs every target through it; LOCAL=1 is the one way round that). A
# printer has /usr/prog/app_startup.sh and so does the replica.
if [ ! -f /usr/prog/app_startup.sh ]; then
    echo "link-prog: not a printer (no /usr/prog/app_startup.sh) -- nothing to do"
    exit 0
fi

# $1 is relative to $MODDIR, $2 is the absolute path the printer reads.
# For the two under prog/ the destinations mirror what FlashForge's own run.sh
# does with the same files, so this stays true as long as that does:
#     cp $WORK_DIR/firmwareExe /usr/prog/PROGRAM/software/
#     cp $WORK_DIR/start.sh    /usr/prog/klipper/start.sh
link_one() {
    src="$MODDIR/$1"
    dst="$2"

    [ -f "$src" ] || { echo "link-prog: no $src -- leaving $dst alone"; return 0; }

    # Already ours and already right: say nothing and change nothing, so a
    # re-run (every .tgz install, every opkg upgrade) is quiet and cheap.
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
        return 0
    fi

    mkdir -p "$(dirname "$dst")"
    # -f, and via a temp name: replacing the file app_startup.sh is about to
    # execute is not something to do non-atomically. `ln -sf` on an existing
    # symlink-to-directory would create a link INSIDE it rather than replace
    # it, which is why the old one goes first.
    rm -f "$dst.anvil-new"
    ln -s "$src" "$dst.anvil-new"
    mv -f "$dst.anvil-new" "$dst"
    echo "link-prog: $dst -> $src"
}

link_one prog/firmwareExe /usr/prog/PROGRAM/software/firmwareExe
link_one prog/start.sh    /usr/prog/klipper/start.sh

# --- the configs ----------------------------------------------------------
# Mod-owned Klipper config, linked rather than copied for the same reason as
# the two above: an `opkg upgrade` should change what the printer reads.
#
# They land in /usr/data/config because that is where printer.cfg is and
# Klipper resolves [include] against the directory of the file doing the
# including -- configfile.py: `dirname = os.path.dirname(source_filename)`,
# the path as opened, NOT the resolved target. So a symlinked
# printer.base.cfg still finds the stock printer.filament.cfg and friends
# beside it, which is what lets those stay stock and unpackaged.
for _f in "$MODDIR"/config/ff-*.cfg; do
    [ -f "$_f" ] || continue
    link_one "config/$(basename "$_f")" "/usr/data/config/$(basename "$_f")"
done
link_one config/printer.base.cfg /usr/data/config/printer.base.cfg

# --- the chamber config, which is the model-specific one ------------------
# THE PRINTER SAYS WHICH MODEL IT IS, so nothing has to ship a marker.
# app_startup.sh is FlashForge's own, carries MACHINE=Creator5Pro (or
# Creator5) at its top, and is restored by any stock flash -- which makes it a
# better answer than anything we could write into $MODDIR, because it stays
# right even when the payload is wrong.
#
# This is what replaced two packages. anvil-klipper-creator5-config and
# -creator5pro-config each owned config/printer.chamber.cfg, so they Conflicted,
# opkg refused the pair with exit 255, and bin/patch.sh had to pick one from
# TARGET_MACHINE at build time. One package ships both under config/chamber/
# and the link is made here, on the machine that knows the answer.
MACHINE=$(sed -n 's/^MACHINE=//p' /usr/prog/app_startup.sh 2>/dev/null | head -1)
case "$MACHINE" in
    Creator5|Creator5Pro)
        link_one "config/chamber/$MACHINE.cfg" /usr/data/config/printer.chamber.cfg ;;
    *)
        # Not fatal, and deliberately so: printer.base.cfg includes
        # printer.chamber.cfg unconditionally, so leaving whatever is already
        # there beats replacing it with a guess. Klipper will say if it is
        # missing, which is a better error than the wrong chamber geometry.
        echo "link-prog: !! MACHINE='$MACHINE' is not a model I ship a chamber config for" >&2
        echo "link-prog:    leaving /usr/data/config/printer.chamber.cfg as it is" >&2 ;;
esac

exit 0
