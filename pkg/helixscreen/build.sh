#!/usr/bin/env bash
# HelixScreen -- unpack upstream's build and add the printer-database entry.
#
# THE JSON BELONGS IN THIS PACKAGE AND NOT IN anvil-core, which is a judgement
# worth stating because it is the only repo-owned file that leaves payload/
# for somebody else's package. printer_database.d/flashforge_creator5.json is
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
. "$(dirname "$0")/../../bin/common.sh"
. pkg/lib.sh

pkg_begin helixscreen || exit 0
pkg_unpack "$HELIX_TGZ"

_src="$PKG_WORK/src/helixscreen"
[ -d "$_src" ] || pkg_die \
    "helixscreen: no helixscreen/ directory in $(basename "$HELIX_TGZ")"

pkg_stage "$_src" "helixscreen"

# The printer-database entry, into the tree's own config directory.
mkdir -p "$PKG_WORK/stage$MODDIR/helixscreen/config/printer_database.d"
cp -f "$ROOT"/payload/helixscreen/printer_database.d/*.json \
      "$PKG_WORK/stage$MODDIR/helixscreen/config/printer_database.d/"

# An optional platform hook. No such file is in the repo, so this never fires
# on a stock checkout -- drop one in assets/ to have it shipped. Carried over
# from bin/patch.sh section 5 unchanged.
[ -f "$ROOT/assets/hooks-creator5.sh" ] && \
    cp -f "$ROOT/assets/hooks-creator5.sh" \
          "$PKG_WORK/stage$MODDIR/helixscreen/assets/config/platform/"

pkg_ship "helixscreen"
pkg_end
