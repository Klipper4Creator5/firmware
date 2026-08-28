#!/usr/bin/env bash
# Build every recipe under pkg/ into the feed, in dependency order, and index
# it.
#
#     ./bin/build-packages.sh              all recipes
#     ./bin/build-packages.sh opkg         that one and everything it needs
#
# WHAT THIS IS. The proof-of-concept half of docs/notes/85-packaging.md: the
# evidence that this repo's cross-builds can be delivered as packages, standing
# beside the tarball rather than replacing it. bin/patch.sh still stages
# libsodium into the payload exactly as it did and `make build` is untouched.
#
# ONE RECIPE PRODUCES ONE PACKAGE, and a recipe that needs a library names it
# in PKG_BUILD_DEPENDS and gets it out of this feed. That is why the loop below
# packages each recipe before it moves to the next one rather than building
# everything and packaging afterwards: pkg/libarchive's configure reads zlib's
# headers out of anvil-zlib_1.3.1-1_mipsel_xburst2.ipk, so that file has to
# exist by the time libarchive is built. The feed is not an output of this
# script so much as the medium it works in.
#
# THE ARCHIVES ARE BUILT BY UPSTREAM'S OWN TOOLS, not by this file. opkg-build
# and opkg-make-index -- and opkg-unbuild, which pkg/lib.sh uses to take them
# apart again -- come from opkg-utils, pinned by commit in versions.env. An
# earlier revision of this work carried a hand-written ar-and-two-tarballs
# script instead, which was 120 lines of this repo re-deriving a format
# somebody else already maintains, including the parts that are easy to get
# subtly wrong (member ORDER, the CONTROL field validation, the tar flags that
# make a build reproducible) and whose failure mode is a package that inspects
# fine and installs nowhere. What is left here is the part that is genuinely
# ours: laying out the tree that opkg-build packages.
#
# IT NEEDS NO STOCK FIRMWARE PACKAGE, which bin/patch.sh does. That is
# deliberate and it is most of why this is a separate script: packaging has to
# be runnable in CI, on a checkout, without a FlashForge .tgz -- otherwise the
# gate only runs where the secrets are and stops being a gate.
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$ROOT/pkg/lib.sh"

say() { printf '>> %s\n' "$*"; }

for t in "$OPKG_BUILD_BIN" "$OPKG_INDEX_BIN" "$OPKG_UNBUILD_BIN"; do
    [ -x "$t" ] || { echo "!! $t is missing -- run ./bin/fetch-assets.sh" >&2; exit 1; }
done

# Reproducible by default. opkg-build reads SOURCE_DATE_EPOCH and, when it is
# set, adds --clamp-mtime to its tar calls on top of the --sort=name it always
# passes; without it every package carries the second it was built and two
# builds of an unchanged tree cannot be compared. Defaulting it to 0 rather
# than to `date` is the difference between reproducible-by-default and
# reproducible-if-you-remember.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

# The recipes to build, expanded to include everything they build against and
# sorted so a dependency always precedes its dependent. Iterating pkg/*/ and
# taking the order the shell gives is wrong the moment there are two recipes:
# alphabetically, libarchive comes before the zlib it needs.
if [ $# -gt 0 ]; then
    REQUESTED=("$@")
else
    mapfile -t REQUESTED < <(pkg_recipes)
fi
[ ${#REQUESTED[@]} -gt 0 ] || { echo "no recipes under pkg/" >&2; exit 1; }
read -r -a RECIPES <<< "$(pkg_order "${REQUESTED[@]}")"

say "order: ${RECIPES[*]}"
mkdir -p "$PKG_FEED"

for r in "${RECIPES[@]}"; do
    [ -f "$ROOT/pkg/$r/build.sh" ] || { echo "!! pkg/$r has no build.sh" >&2; exit 1; }

    # Every recipe caches on its own stamp -- pkg/lib.sh's pkg_begin is that
    # check -- so this is a no-op on a warm tree and costs a process spawn.
    bash "$ROOT/pkg/$r/build.sh"

    # Sourced in a subshell, one recipe at a time. PKG_DEPENDS from one recipe
    # leaking into the next is precisely the bug that makes a package declare a
    # dependency nobody wrote down, and it would install fine and stay wrong.
    (
        pkg_conf "$r"

        for v in PKG_NAME PKG_VERSION PKG_ROOT PKG_DESCRIPTION; do
            [ -n "${!v}" ] || { echo "!! pkg/$r/pkg.conf leaves $v empty" >&2; exit 1; }
        done
        [ -d "$PKG_ROOT" ] || {
            echo "!! pkg/$r: PKG_ROOT '$PKG_ROOT' does not exist -- did build.sh run?" >&2
            exit 1; }

        # THE ABI GATE, AT THE PACKAGE BOUNDARY. bin/patch.sh runs the same
        # check over the staged payload, and that does not cover this: a
        # package can be built by `make packages` on a machine that never runs
        # patch.sh. An .ipk is a shipping vehicle, so it gets gated like one --
        # and it is gated over PKG_ROOT rather than over the finished archive
        # because readelf cannot look inside a tarball.
        n=$(mips_abi_gate "$PKG_ROOT") || exit 1
        say "$PKG_NAME: $n ELF object(s) pass nan2008/o32/mips32r2"

        # ---------------------------------------------------- the layout
        #
        # opkg-build packages a DIRECTORY: the file tree exactly as it will
        # appear on the target, plus a CONTROL/ subdirectory it lifts the
        # metadata out of and does not ship. So the recipe's tree is laid down
        # under $MODDIR here -- work/pkg/libsodium/lib/libsodium.so.26.2.0
        # becomes ./usr/data/anvil/lib/libsodium.so.26.2.0 -- which is why
        # `opkg install` needs no prefix of its own later, and why a package
        # built for this mod can never land on the rootfs by accident: every
        # path it owns is under /usr/data.
        #
        # cp -a and not cp: libsodium ships libsodium.so -> .so.26 ->
        # .so.26.2.0, and the first of those is the name libnacl's dlopen
        # fallback constructs. A copy that dereferenced them would put three
        # identical 400KB files in the package and still work, until somebody
        # wondered why it had tripled in size.
        LAYOUT="work/.ipk-$PKG_NAME"
        rm -rf "$LAYOUT"
        mkdir -p "$LAYOUT$MODDIR" "$LAYOUT/CONTROL"
        cp -a "$PKG_ROOT/." "$LAYOUT$MODDIR/"
        # PKG_EXCLUDE is a space-separated list of patterns and is meant
        # to word-split here.
        # shellcheck disable=SC2086
        for p in $PKG_EXCLUDE; do
            find "$LAYOUT$MODDIR" -name "$p" -exec rm -rf {} + 2>/dev/null || true
        done
        [ -n "$(find "$LAYOUT$MODDIR" \( -type f -o -type l \) -print -quit)" ] \
            || { echo "!! pkg/$r staged nothing -- empty package refused" >&2; exit 1; }

        # The five fields opkg-build's own required_field() insists on, plus
        # the ones opkg reads. Description LAST because it is the only one that
        # may continue onto further lines, and a continuation line is defined
        # as one starting with whitespace -- so a field after it would have to
        # be unindented, and an unindented line is where the next stanza begins.
        {
            printf 'Package: %s\n' "$PKG_NAME"
            printf 'Version: %s-%s\n' "$PKG_VERSION" "$PKG_RELEASE"
            printf 'Architecture: %s\n' "$PKG_ARCH"
            printf 'Maintainer: %s\n' "$PKG_MAINTAINER"
            printf 'Section: %s\n' "$PKG_SECTION"
            printf 'Priority: optional\n'
            [ -n "$PKG_DEPENDS" ] && printf 'Depends: %s\n' "$PKG_DEPENDS"
            printf 'Description: %s\n' "$PKG_DESCRIPTION"
        } > "$LAYOUT/CONTROL/control"

        # -o 0 -g 0: every file in the archive is owned by root. Without them
        # opkg-build hands tar whatever uid the build ran as, which is a
        # developer's account on one machine and a CI runner's on another --
        # two packages that differ in nothing that matters and compare
        # unequal.
        #
        # BOTH PATHS ABSOLUTE, and that is a requirement rather than a style:
        # opkg-build builds its scratch directory as "$dest_dir/IPKG_BUILD.$$"
        # and then reads it from inside `( cd $pkg_dir/CONTROL && ... )`, so a
        # relative destination resolves against the wrong directory and the
        # build dies on a missing control_list -- an error that names a
        # temporary file and not the argument that caused it.
        "$OPKG_BUILD_BIN" -o 0 -g 0 "$PWD/$LAYOUT" "$PKG_FEED" > /dev/null
        rm -rf "$LAYOUT"

        ipk="$PKG_FEED/${PKG_NAME}_${PKG_VERSION}-${PKG_RELEASE}_${PKG_ARCH}.ipk"
        [ -f "$ipk" ] || { echo "!! opkg-build produced no $ipk" >&2; exit 1; }
        say "$PKG_NAME: $(basename "$ipk") ($(du -h "$ipk" | cut -f1))"
    )
done

# ------------------------------------------------------------------ the index
#
# `Packages` is what turns a directory of .ipk files into something opkg can be
# pointed at: one stanza per package -- the package's own control file, plus
# the fields only the feed can know (where the file is, how big it is, what it
# hashes to). opkg-make-index is upstream's tool for exactly this and is used
# for exactly the same reason opkg-build is.
#
# THE HASH IS THE POINT, not the convenience. It is the same argument
# versions.env makes about vendored tarballs: once the index is trusted, the
# packages under it do not have to be, because opkg refuses one whose sha256
# does not match its stanza. Signing the INDEX (usign, phase 3) therefore signs
# the whole feed, and nothing has to sign each package.
#
# Both plain and gzipped, because opkg asks for Packages.gz first and falls
# back to Packages, and a feed served off a USB stick or a laptop's `python3 -m
# http.server` is easier to eyeball when the plain one is there too.
#
# --checksum sha256 IS NOT THE DEFAULT and has to be asked for: opkg-make-index
# writes MD5Sum alone unless told otherwise, and an index whose only integrity
# claim is MD5 cannot carry the argument above -- a collision against a stanza
# is a solved problem, and the whole point of trusting the index instead of the
# packages is that it is the thing worth attacking. md5 is kept beside it
# because opkg still reports it and some tooling looks for it; the sha256 is
# what actually gates an install.
say "index: writing $PKG_FEED/Packages"
( cd "$PKG_FEED" && python3 "$OPKG_INDEX_BIN" --checksum md5 --checksum sha256 . > Packages )
gzip -n -9 -c "$PKG_FEED/Packages" > "$PKG_FEED/Packages.gz"
say "index: $(grep -c '^Package:' "$PKG_FEED/Packages") package(s) in $PKG_FEED"
