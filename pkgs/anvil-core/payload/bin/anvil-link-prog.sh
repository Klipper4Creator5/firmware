#!/bin/sh
# Point the stock boot path at the files this package owns.
#
# Two of the mod's files have to sit on the FIRMWARE partition, because
# FlashForge's own scripts look for them by absolute path: app_startup.sh runs
# /usr/prog/PROGRAM/software/firmwareExe, and klipperDaemon is started from
# /usr/prog/klipper/start.sh. Neither path is ours to move.
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

# source-under-$MODDIR/prog  ->  the absolute path the stock boot path reads.
# The destinations mirror what FlashForge's own run.sh does with the same two
# files, so this stays true as long as that does:
#     cp $WORK_DIR/firmwareExe /usr/prog/PROGRAM/software/
#     cp $WORK_DIR/start.sh    /usr/prog/klipper/start.sh
link_one() {
    src="$MODDIR/prog/$1"
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

link_one firmwareExe /usr/prog/PROGRAM/software/firmwareExe
link_one start.sh    /usr/prog/klipper/start.sh

exit 0
