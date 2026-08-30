#!/usr/bin/env bash
# HelixScreen -- unpack upstream's build and add the printer-database entry.
#
# THIS RECIPE HAS BOTH A TARBALL AND A payload/, which is the shape every
# recipe that adds something of ours to somebody else's tree now has: the
# tarball is the source, and pkgs/helixscreen/payload/ is the $MODDIR overlay
# laid out exactly as it lands. printer_database.d/flashforge_creator5.json is
# what makes HelixScreen detect this machine as a tool changer: it is
# meaningless without the tree it configures, it is read from inside that
# tree's own config directory, and if HelixScreen is ever removed it should go
# with it. A file whose entire purpose is to configure one package is owned by
# that package.
#
# NO pkg_toolchain: upstream ships the binaries built. That is also why this
# recipe compiles nothing and still declares an architecture -- what is in the
# tarball is mipsel ELF, and bin/build-packages.sh gates it on the way into
# the .ipk.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin helixscreen || exit 0
pkg_unpack "$HELIX_TGZ"

_src="$PKG_WORK/src/helixscreen"
[ -d "$_src" ] || pkg_die \
    "helixscreen: no helixscreen/ directory in $(basename "$HELIX_TGZ")"

pkg_stage "$_src" "helixscreen"

# Our half, staged OVER the unpacked tarball rather than beside it: the
# printer-database entry belongs inside HelixScreen's own config directory,
# and payload/ already spells that path, so this is a copy with no
# destinations written down. cp -a, and -T-free, because the tree it lands on
# exists -- pkg_stage would refuse to merge into it.
#
# An optional platform hook rides the same way: no hooks-creator5.sh is in the
# repo, so a stock checkout ships nothing extra, and dropping one at
# payload/helixscreen/assets/config/platform/ has it shipped with no edit
# here. Carried over from bin/payload.sh section 5 unchanged.
cp -a "$PKG_DIR/payload/." "$PKG_WORK/stage$MODDIR/"

pkg_ship "helixscreen"
pkg_end
