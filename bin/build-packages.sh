#!/usr/bin/env bash
# Build every recipe under pkgs/ into the feed, in dependency order, and index
# it.
#
#     ./bin/build-packages.sh              all recipes
#     ./bin/build-packages.sh opkg         that one and everything it needs
#
# WHAT THIS IS. The feed bin/patch.sh installs to make the payload, so this
# runs before a build rather than beside it. It still needs no stock FlashForge
# package, which is why it is a separate script -- see the end of this header.
#
# ONE RECIPE PRODUCES ONE PACKAGE, and a recipe that needs a library names it
# in PKG_BUILD_DEPENDS and gets it out of this feed. That is why the loop below
# packages each recipe before it moves to the next one rather than building
# everything and packaging afterwards: pkgs/3rdparty/libarchive's configure reads zlib's
# headers out of anvil-zlib_1.3.1-1_mipsel_xburst2.ipk, so that file has to
# exist by the time libarchive is built. The feed is not an output of this
# script so much as the medium it works in.
#
# THE ARCHIVES ARE BUILT BY UPSTREAM'S OWN TOOLS, not by this file. opkg-build
# and opkg-make-index -- and opkg-unbuild, which pkgs/lib.sh uses to take them
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
. "$ROOT/pkgs/lib.sh"

say() { printf '>> %s\n' "$*"; }

for t in "$OPKG_BUILD_BIN" "$OPKG_INDEX_BIN" "$OPKG_UNBUILD_BIN"; do
    [ -x "$t" ] || { echo "!! $t is missing -- run ./bin/fetch-assets.sh" >&2; exit 1; }
done

# Reproducible by default. opkg-build reads SOURCE_DATE_EPOCH and, when it is
# set, adds --clamp-mtime to its tar calls on top of the --sort=name it always
# passes; without it every package carries the second it was built and two
# builds of an unchanged tree cannot be compared. Defaulting it rather than
# leaving it to `date` is the difference between reproducible-by-default and
# reproducible-if-you-remember.
#
# THE DEFAULT IS 1 AND NOT 0, WHICH IS NOT A TYPO. It was 0, and OpenSSL was
# the one package in the feed that would not reproduce: two builds an hour
# apart differed in exactly one object, libcrypto-lib-cversion.o, which
# carries a "built on:" string. OpenSSL does support SOURCE_DATE_EPOCH --
# util/mkbuildinf.pl reads it -- but the line is
#
#     my $date = gmtime($ENV{'SOURCE_DATE_EPOCH'} || time()) . " UTC";
#
# and that is Perl's ||, not //. Zero is FALSE in Perl, so the one value we
# were passing is the single value that silently falls through to the current
# time. One second past the epoch is just as fixed and is true.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1}"

# The recipes to build, expanded to include everything they build against and
# sorted so a dependency always precedes its dependent. Iterating the recipe
# directories and
# taking the order the shell gives is wrong the moment there are two recipes:
# alphabetically, libarchive comes before the zlib it needs.
if [ $# -gt 0 ]; then
    REQUESTED=("$@")
else
    mapfile -t REQUESTED < <(pkg_recipes)
fi
[ ${#REQUESTED[@]} -gt 0 ] || { echo "no recipes under pkgs/" >&2; exit 1; }
read -r -a RECIPES <<< "$(pkg_order "${REQUESTED[@]}")"

say "order: ${RECIPES[*]}"
mkdir -p "$PKG_FEED"

for r in "${RECIPES[@]}"; do
    _d=$(pkg_dir "$r") \
        || { echo "!! no recipe named '$r'" >&2; exit 1; }
    [ -f "$_d/build.sh" ] || { echo "!! $_d has no build.sh" >&2; exit 1; }

    # Every recipe caches on its own stamp -- pkgs/lib.sh's pkg_begin is that
    # check -- so this is a no-op on a warm tree and costs a process spawn.
    bash "$_d/build.sh"

    # Sourced in a subshell, one recipe at a time. PKG_DEPENDS from one recipe
    # leaking into the next is precisely the bug that makes a package declare a
    # dependency nobody wrote down, and it would install fine and stay wrong.
    (
        pkg_conf "$r"

        for v in PKG_NAME PKG_VERSION PKG_ROOT PKG_DESCRIPTION; do
            [ -n "${!v}" ] || { echo "!! $r's pkg.conf leaves $v empty" >&2; exit 1; }
        done
        [ -d "$PKG_ROOT" ] || {
            echo "!! $r: PKG_ROOT '$PKG_ROOT' does not exist -- did build.sh run?" >&2
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
        # -maxdepth 1 is not a micro-optimisation. PKG_EXCLUDE is always
        # ".version", the stamp pkg_end writes at the ROOT of a recipe's
        # output, but `find -name` matches a basename at any depth -- and
        # Mainsail ships a .version of its own at www/mainsail/.version. This
        # deleted it, and anvil-mainsail shipped without it for as long as the
        # payload was copied from work/pkg rather than from the package.
        #
        # PKG_EXCLUDE is a space-separated list of patterns, meant to split.
        # shellcheck disable=SC2086
        for p in $PKG_EXCLUDE; do
            find "$LAYOUT$MODDIR" -maxdepth 1 -name "$p" -exec rm -rf {} + 2>/dev/null || true
        done
        [ -n "$(find "$LAYOUT$MODDIR" \( -type f -o -type l \) -print -quit)" ] \
            || { echo "!! $r staged nothing -- empty package refused" >&2; exit 1; }

        # ------------------------------------------- the runtime/dev split
        #
        # A library that is BOTH linked against and run produces two kinds of
        # file from one build: binaries a printer executes, and headers and a
        # static archive only a build machine will ever open. PKG_DEV_FILES
        # names the second kind, and everything it matches is MOVED out of the
        # layout into a second one that becomes <name>-dev.
        #
        # WHY MOVE RATHER THAN COPY. A file in both packages is a file two
        # packages own, and opkg resolves that by letting whichever installed
        # last win -- silently. The dev half is a partition of the build, not a
        # view onto it, so every path lands in exactly one archive and
        # `ipk-install remove` can never delete a file the other package still
        # needs.
        #
        # WHAT IT BUYS: the headers and .a files stop being installed on a
        # printer that has no compiler, and the feed still contains everything
        # the next recipe needs to build against -- in a package that says so
        # in its name and its section.
        DEVLAYOUT="work/.ipk-$PKG_NAME-dev"
        rm -rf "$DEVLAYOUT"
        if [ -n "$PKG_DEV_FILES" ]; then
            mkdir -p "$DEVLAYOUT$MODDIR" "$DEVLAYOUT/CONTROL"
            # shellcheck disable=SC2086
            for g in $PKG_DEV_FILES; do
                for m in "$LAYOUT$MODDIR"/$g; do
                    [ -e "$m" ] || continue
                    rel=${m#"$LAYOUT$MODDIR"/}
                    mkdir -p "$DEVLAYOUT$MODDIR/$(dirname "$rel")"
                    mv "$m" "$DEVLAYOUT$MODDIR/$rel"
                done
            done
            [ -n "$(find "$DEVLAYOUT$MODDIR" \( -type f -o -type l \) -print -quit)" ] \
                || { echo "!! $r sets PKG_DEV_FILES and none of it matched" >&2; exit 1; }
            # Directories the move emptied. Left behind they would be shipped
            # as an empty include/ on every printer -- harmless, and exactly
            # the sort of harmless that accumulates.
            find "$LAYOUT$MODDIR" -type d -empty -delete 2>/dev/null || true
        fi

        # ------------------------------------------- deterministic modes
        #
        # A PACKAGE MUST NOT DEPEND ON WHO BUILT IT. opkg-build's `-o 0 -g 0`
        # settles ownership and SOURCE_DATE_EPOCH settles timestamps, and
        # neither touches PERMISSIONS -- which arrive from whatever the source
        # archive happened to carry, filtered through the umask of whoever
        # extracted it.
        #
        # Measured: the Moonraker and HelixScreen packages built in the pinned
        # container and on a developer's host differed, and nothing else did.
        # GNU tar restores a directory's exact mode when it runs as root and
        # applies the umask when it does not, so Moonraker's own drwxrwxr-x
        # tree came out 0775 in the container and 0755 outside it. Two
        # byte-different packages containing the same files, and no way to tell
        # from the outside which one a printer got.
        #
        # 0755 for directories, 0755 for anything executable, 0644 for
        # everything else -- the same normalisation every distro's packaging
        # applies, for the same reason. Symlinks are left alone: their mode is
        # not meaningful and chmod would follow them to the target.
        for lay in "$LAYOUT" "$DEVLAYOUT"; do
            [ -d "$lay$MODDIR" ] || continue
            find "$lay$MODDIR" -type d -exec chmod 0755 {} +
            find "$lay$MODDIR" -type f -perm -u+x -exec chmod 0755 {} +
            find "$lay$MODDIR" -type f ! -perm -u+x -exec chmod 0644 {} +
        done

        # emit <layout> <name> <section> <depends> <description>
        #
        # The five fields opkg-build's own required_field() insists on, plus
        # the ones opkg reads. Description LAST because it is the only one that
        # may continue onto further lines, and a continuation line is defined
        # as one starting with whitespace -- so a field after it would have to
        # be unindented, and an unindented line is where the next stanza begins.
        emit() {
            _lay=$1; _nm=$2; _sect=$3; _dep=$4; _desc=$5
            # ONE LINE, WHATEVER THE RECIPE WROTE. A Depends list of thirteen
            # packages does not fit on one line of a pkg.conf anybody wants to
            # read, so anvil-moonraker's is wrapped -- and a raw newline inside
            # a control field is a new stanza to some parsers and a folded
            # continuation to others. Unquoted, so the shell splits on every
            # run of whitespace and rejoins with single spaces.
            # shellcheck disable=SC2086
            _dep=$(echo $_dep)
            {
                printf 'Package: %s\n' "$_nm"
                printf 'Version: %s-%s\n' "$PKG_VERSION" "$PKG_RELEASE"
                printf 'Architecture: %s\n' "$PKG_ARCH"
                printf 'Maintainer: %s\n' "$PKG_MAINTAINER"
                printf 'Section: %s\n' "$_sect"
                printf 'Priority: optional\n'
                [ -n "$_dep" ] && printf 'Depends: %s\n' "$_dep"
                # PROVIDES AND CONFLICTS, TOGETHER, BECAUSE THEY ONLY WORK
                # TOGETHER. A virtual name that several packages Provide lets
                # a dependency be satisfied by any one of them -- which is
                # what "install either chamber config" means -- and on its own
                # it also lets a printer install BOTH, whereupon two packages
                # own one path and opkg resolves that by letting whichever
                # unpacked last win, silently. Conflicts on the same virtual
                # name is what makes "either" mean "exactly one".
                # shellcheck disable=SC2086
                [ -n "$PKG_PROVIDES" ] \
                    && printf 'Provides: %s\n' "$(echo $PKG_PROVIDES)"
                # shellcheck disable=SC2086
                [ -n "$PKG_CONFLICTS" ] \
                    && printf 'Conflicts: %s\n' "$(echo $PKG_CONFLICTS)"
                printf 'Description: %s\n' "$_desc"
            } > "$_lay/CONTROL/control"

            # -o 0 -g 0: every file in the archive is owned by root. Without
            # them opkg-build hands tar whatever uid the build ran as, which is
            # a developer's account on one machine and a CI runner's on another
            # -- two packages that differ in nothing that matters and compare
            # unequal.
            #
            # BOTH PATHS ABSOLUTE, and that is a requirement rather than a
            # style: opkg-build builds its scratch directory as
            # "$dest_dir/IPKG_BUILD.$$" and then reads it from inside
            # `( cd $pkg_dir/CONTROL && ... )`, so a relative destination
            # resolves against the wrong directory and the build dies on a
            # missing control_list -- an error that names a temporary file and
            # not the argument that caused it.
            "$OPKG_BUILD_BIN" -o 0 -g 0 "$PWD/$_lay" "$PKG_FEED" > /dev/null
            rm -rf "$_lay"

            _ipk="$PKG_FEED/${_nm}_${PKG_VERSION}-${PKG_RELEASE}_${PKG_ARCH}.ipk"
            [ -f "$_ipk" ] || { echo "!! opkg-build produced no $_ipk" >&2; exit 1; }
            say "$_nm: $(basename "$_ipk") ($(du -h "$_ipk" | cut -f1))"
        }

        # The runtime half, unless the split took everything -- which is the
        # normal case for a library that is only ever linked against, like
        # zlib. An empty runtime package would be a name in the feed that
        # installs nothing.
        if [ -n "$(find "$LAYOUT$MODDIR" \( -type f -o -type l \) -print -quit)" ]; then
            emit "$LAYOUT" "$PKG_NAME" "$PKG_SECTION" "$PKG_DEPENDS" "$PKG_DESCRIPTION"
        else
            rm -rf "$LAYOUT"
        fi

        # The dev half depends on the runtime half by name when there is one:
        # its headers describe that build, and installing them against a
        # different version of the library is the mistake the dependency
        # prevents.
        if [ -d "$DEVLAYOUT/CONTROL" ]; then
            if [ -f "$PKG_FEED/${PKG_NAME}_${PKG_VERSION}-${PKG_RELEASE}_${PKG_ARCH}.ipk" ]; then
                _devdep="$PKG_NAME"
            else
                _devdep=""
            fi
            emit "$DEVLAYOUT" "$PKG_NAME-dev" libdevel "$_devdep" \
                 "${PKG_DEV_DESCRIPTION:-Headers and static library for $PKG_NAME. Nothing installs this on a printer; it exists to be built against.}"
        fi
    )
done

# ------------------------------------------------------------------ the prune
#
# A FULL BUILD OWNS THE FEED. Every .ipk here should be one some recipe under
# pkgs/ produces right now; anything else is an orphan, and an orphan in a feed
# is worse than a stray file because opkg-make-index puts it in the index and
# a printer can then install it.
#
# They appear the moment a package is RENAMED, which is not hypothetical: the
# runtime/dev split renamed anvil-zlib to anvil-zlib-dev, and the old archive
# sat in the feed advertising a package no recipe had built since. It would
# have installed perfectly and been impossible to rebuild.
#
# Only on a full build. `./bin/build-packages.sh s6` asks for one recipe and
# its dependencies and must not delete everything it did not ask about --
# which is also why the expected set below is computed from ALL recipes rather
# than from the ones this run happened to build.
if [ $# -eq 0 ]; then
    expected=""
    for r in $(pkg_recipes); do
        for v in '' dev; do
            expected="$expected $(basename "$(pkg_ipk "$r" "$v")")"
        done
    done
    for f in "$PKG_FEED"/*.ipk; do
        [ -e "$f" ] || continue
        case " $expected " in
            *" $(basename "$f") "*) continue ;;
        esac
        say "prune: $(basename "$f") -- no recipe produces this any more"
        rm -f "$f"
    done
fi

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
