#!/usr/bin/env bash
# Build every recipe under pkg/ into work/packages/, then write the feed index
# that makes that directory an opkg repository rather than a pile of files.
#
#     ./bin/build-packages.sh              all recipes
#     ./bin/build-packages.sh libsodium    just that one
#
# WHAT THIS IS. The proof-of-concept half of docs/notes/85-packaging.md: the
# evidence that this repo's cross-builds can be delivered as packages, standing
# beside the tarball rather than replacing it. Nothing here is on the release
# path yet. bin/patch.sh still stages libsodium into the payload exactly as it
# did, `make build` is untouched, and the .ipk this produces is an artefact
# nobody installs until the migration's phase 2 lands an installer on the
# printer.
#
# THE POINT OF IT STANDING BESIDE. Both copies of libsodium now come out of
# pkg/libsodium/build.sh -- one goes into anvil.tar.xz and one goes into an
# .ipk -- so the packaged library cannot drift from the shipped one while the
# recipe is the only place either is compiled. qa/static/test_ipk.py asserts
# that: it opens the .ipk and compares what is inside against $SODIUM_BUILD
# file by file. When phase 2 makes the package the shipping vehicle, that test
# is what says the switch changed nothing.
#
# IT NEEDS NO STOCK FIRMWARE PACKAGE, which bin/patch.sh does. That is
# deliberate and it is most of why this is a separate script: packaging has to
# be runnable in CI, on a checkout, without a FlashForge .tgz -- otherwise the
# gate only runs where the secrets are and stops being a gate.
set -euo pipefail
. "$(dirname "$0")/common.sh"

say() { printf '>> %s\n' "$*"; }

OUTDIR="${OUTDIR:-work/packages}"

# The recipes, in the order pkg/ lists them. Order is not dependency order and
# does not need to be: opkg resolves Depends at install time from the index,
# not from the order the feed was built in. It will matter to a build that has
# to LINK one package against another -- the python site-packages against the
# interpreter -- and that is the phase-1 problem, not this one.
if [ $# -gt 0 ]; then
    RECIPES=("$@")
else
    RECIPES=()
    for d in pkg/*/; do
        [ -f "$d/pkg.conf" ] && RECIPES+=("$(basename "$d")")
    done
fi
[ ${#RECIPES[@]} -gt 0 ] || { echo "no recipes under pkg/" >&2; exit 1; }

mkdir -p "$OUTDIR"

for r in "${RECIPES[@]}"; do
    [ -f "pkg/$r/pkg.conf" ] || { echo "!! no recipe pkg/$r/pkg.conf" >&2; exit 1; }

    # Build first. Every recipe's build.sh is responsible for its own caching
    # -- libsodium's is stamped on the version in versions.env -- so this is a
    # no-op on a warm tree and the whole script costs a few process spawns.
    if [ -x "pkg/$r/build.sh" ] || [ -f "pkg/$r/build.sh" ]; then
        bash "pkg/$r/build.sh"
    fi

    # Sourced in a subshell, one recipe at a time. PKG_DEPENDS from one recipe
    # leaking into the next is precisely the bug that makes a package declare a
    # dependency nobody wrote down, and it would install fine and stay wrong.
    (
        PKG_NAME=''; PKG_VERSION=''; PKG_RELEASE=1; PKG_SECTION=libs
        PKG_ROOT=''; PKG_EXCLUDE=''; PKG_DEPENDS=''; PKG_DESCRIPTION=''
        # shellcheck disable=SC1090
        . "pkg/$r/pkg.conf"

        for v in PKG_NAME PKG_VERSION PKG_ROOT PKG_DESCRIPTION; do
            [ -n "${!v}" ] || { echo "!! pkg/$r/pkg.conf leaves $v empty" >&2; exit 1; }
        done
        [ -d "$PKG_ROOT" ] || {
            echo "!! pkg/$r: PKG_ROOT '$PKG_ROOT' does not exist -- did build.sh run?" >&2
            exit 1; }

        # THE ABI GATE, AT THE PACKAGE BOUNDARY. bin/patch.sh runs the same
        # check over the staged payload, and that does not cover this: a
        # package can be built by `make packages` on a machine that never runs
        # patch.sh at all. An .ipk is a shipping vehicle, so it gets gated like
        # one -- and it is gated over PKG_ROOT rather than over the finished
        # archive because readelf cannot look inside a tarball.
        n=$(mips_abi_gate "$PKG_ROOT") || exit 1
        say "$PKG_NAME: $n ELF object(s) pass nan2008/o32/mips32r2"

        # shellcheck disable=SC2086
        # $PKG_EXCLUDE is a space-separated list of patterns and is meant to
        # word-split; mkipk.sh takes one --exclude per pattern.
        EXCL=()
        for p in $PKG_EXCLUDE; do EXCL+=(--exclude "$p"); done

        ipk=$(bin/mkipk.sh \
            --name "$PKG_NAME" \
            --version "$PKG_VERSION" \
            --release "$PKG_RELEASE" \
            --arch "$IPK_ARCH" \
            --prefix "$MODDIR" \
            --root "$PKG_ROOT" \
            --outdir "$OUTDIR" \
            --section "$PKG_SECTION" \
            --depends "$PKG_DEPENDS" \
            --description "$PKG_DESCRIPTION" \
            ${EXCL+"${EXCL[@]}"})
        say "$PKG_NAME: $ipk ($(du -h "$ipk" | cut -f1))"
    )
done

# ------------------------------------------------------------------ the index
#
# `Packages` is what turns a directory of .ipk files into something opkg can be
# pointed at: one stanza per package -- the package's own control file, plus
# the three fields only the feed can know (where the file is, how big it is,
# what it hashes to). opkg-make-index is the upstream tool for this and it is a
# python script; this is the same output in fifteen lines of shell, which is
# one fewer dependency to pin and one fewer thing to explain.
#
# THE HASH IS THE POINT, not the convenience. It is the same argument
# versions.env makes about vendored tarballs: once the index is trusted, the
# packages under it do not have to be, because opkg refuses one whose sha256
# does not match the stanza. Signing the INDEX (usign, phase 3) therefore
# signs the whole feed, and nothing has to sign each package.
#
# Both plain and gzipped, because opkg asks for Packages.gz first and falls
# back to Packages, and a feed served off a USB stick or a laptop's `python3
# -m http.server` is easier to eyeball when the plain one is there too.
say "index: writing $OUTDIR/Packages"
: > "$OUTDIR/Packages"
for f in "$OUTDIR"/*.ipk; do
    [ -e "$f" ] || continue
    # The control file straight out of the package, which is why the stanza
    # cannot disagree with what opkg reads after installing: it IS what opkg
    # reads. ar p writes one member to stdout.
    ar p "$f" control.tar.gz | tar -xzO ./control >> "$OUTDIR/Packages"
    {
        printf 'Filename: %s\n' "$(basename "$f")"
        printf 'Size: %s\n' "$(stat -c %s "$f")"
        printf 'SHA256sum: %s\n' "$(sha256sum "$f" | cut -d' ' -f1)"
        printf '\n'
    } >> "$OUTDIR/Packages"
done
gzip -n -9 -c "$OUTDIR/Packages" > "$OUTDIR/Packages.gz"
say "index: $(grep -c '^Package:' "$OUTDIR/Packages") package(s) in $OUTDIR"
