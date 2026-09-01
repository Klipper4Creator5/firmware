#!/usr/bin/env bash
# Lay the built feed out the way $FEED_URL serves it, and optionally copy it
# there. Outside the 1/3-2/3-3/3 chain that makes a .tgz: this publishes the
# same packages that went into one.
#
#     ./bin/publish-feed.sh                     stage work/feed-site/ only
#     ./bin/publish-feed.sh user@host:/srv/apk  stage, then rsync it there
#     ./bin/publish-feed.sh /srv/apk            a local directory works too
#
# The destination is the directory $FEED_URL names. A printer reads
#
#     $FEED_URL/$IPK_ARCH/$PKG_INDEX_NAME
#
# and this script's whole job is to make that path exist, with the packages
# the index names beside it.
#
# NOT A BUILD STEP AND NOT IN THE CONTAINER, unlike every other script here:
# it copies files that are already built, and the credentials that reach the
# host are the operator's own. `make packages` first; this second.
#
# THE INDEX GOES LAST, and that is the only ordering that matters. It names
# every package by sha256, so a mirror that has the new index and not yet the
# new packages hands printers a checksum for a file that 404s. Packages first
# means the worst intermediate state is a feed that is merely out of date.
#
# NOTHING IS DELETED at the far end. An old package nothing references costs
# disk and is what a printer mid-upgrade is still fetching; removing them is a
# separate, deliberate act.
set -euo pipefail
. "$(dirname "$0")/common.sh"

say() { printf '>> %s\n' "$*"; }

DEST="${1:-}"
SITE="$ROOT/work/feed-site"

[ -f "$PKG_FEED/$PKG_INDEX_NAME" ] || {
    echo "!! no index at $PKG_FEED/$PKG_INDEX_NAME" >&2
    echo "   run 'make packages' first -- this script publishes a feed, it" >&2
    echo "   does not build one." >&2
    exit 1; }

# AN UNSIGNED FEED IS FINE TO BUILD AND NOT FINE TO SERVE. The build lane runs
# on a bare checkout with no key on purpose (bin/build-packages.sh says why),
# but a printer that fetches from a public URL has nothing but the signature
# to tell our packages from someone else's -- and apk would need
# --allow-untrusted to install them at all.
if [ -z "${APK_SIGN_KEY:-}" ] && [ "${ALLOW_UNSIGNED:-0}" != "1" ]; then
    echo "!! this feed is unsigned: APK_SIGN_KEY is empty in $CONFIG_ENV." >&2
    echo "   A printer verifies packages against the public half that ships" >&2
    echo "   in anvil-core, so an unsigned feed is one no printer installs" >&2
    echo "   from. ./bin/apk-keygen.sh makes the pair, then rebuild:" >&2
    echo "     make packages" >&2
    echo "   ALLOW_UNSIGNED=1 to publish anyway." >&2
    exit 1
fi

# --- the tree that gets served
# Rebuilt from scratch each time: a stale .apk here is one the index does not
# name, and rsync would upload it forever.
rm -rf "$SITE"
mkdir -p "$SITE/$IPK_ARCH"
cp -a "$PKG_FEED"/*."$PKG_EXT" "$SITE/$IPK_ARCH/"
cp -a "$PKG_FEED/$PKG_INDEX_NAME" "$SITE/$IPK_ARCH/"
say "staged $(ls "$SITE/$IPK_ARCH"/*."$PKG_EXT" | wc -l) package(s) into $SITE/$IPK_ARCH"
say "serve that tree at $FEED_URL -- printers read $FEED_URL/$IPK_ARCH/$PKG_INDEX_NAME"

if [ -z "$DEST" ]; then
    echo
    echo "No destination given, so nothing was copied. To publish:"
    echo "    ./bin/publish-feed.sh user@host:/path/to/apk"
    exit 0
fi

command -v rsync >/dev/null || { echo "!! rsync is not installed" >&2; exit 1; }

# Two passes, packages then index, for the reason in the header. --delete on
# neither.
say "publishing packages to $DEST"
rsync -a --info=stats1 --exclude "$PKG_INDEX_NAME" "$SITE/" "${DEST%/}/"
say "publishing the index"
rsync -a --info=stats1 "$SITE/$IPK_ARCH/$PKG_INDEX_NAME" "${DEST%/}/$IPK_ARCH/"

echo
echo "Published. A printer picks it up with:"
echo "    apk update && apk upgrade"
