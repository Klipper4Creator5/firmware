#!/usr/bin/env bash
# Mainsail -- unpack the published zip into the prefix's web root.
#
# WHAT A RECIPE LOOKS LIKE WHEN THERE IS NOTHING TO COMPILE. No
# pkg_toolchain, because no compiler is involved; no pkg_deps, because there
# is nothing to build against. Three lines do the work: name the source,
# put it where it goes, say what ships.
#
# THE ZIP HAS NO TOP-LEVEL DIRECTORY. Mainsail publishes index.html, assets/
# and the rest at the root of the archive, so $PKG_WORK/src IS the web root
# after unpacking and gets copied wholesale to www/mainsail. This was checked
# against the pinned artefact rather than assumed -- an archive that grew a
# wrapper directory would put the UI at www/mainsail/mainsail-2.18.2/ and
# serve a 404 from a build that looked clean, so the assertion below is the
# thing standing between that and a printer.
set -euo pipefail
. "$(dirname "$0")/../../bin/common.sh"
. pkg/lib.sh

pkg_begin mainsail || exit 0
pkg_unpack "$MAINSAIL_ZIP"

[ -f "$PKG_WORK/src/index.html" ] || pkg_die \
    "mainsail: no index.html at the root of $(basename "$MAINSAIL_ZIP") -- the
     archive's shape changed and www/mainsail would be served empty"

pkg_stage "$PKG_WORK/src" "www/mainsail"
pkg_ship "www/mainsail"
pkg_end
