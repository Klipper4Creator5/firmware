# The part of a cross-build that is the same for every package.
#
# Sourced by pkg/*/build.sh, after bin/common.sh.
#
# ONE RECIPE BUILDS ONE SOURCE. That is the rule this file exists to make
# cheap. A recipe unpacks one source, builds it, and ships it; anything it
# needs to build against arrives as a package that some other recipe produced,
# unpacked out of the feed by pkg_deps. The alternative -- a recipe that builds
# its own dependencies inline, which is what pkg/opkg used to do with zlib and
# libarchive, and what bin/patch.sh section 5b did with skalibs -- makes every
# library an invisible detail of whoever needed it first: unversioned,
# unshippable, and rebuilt from scratch by the next consumer. zlib was the
# proof, cross-built twice in one tree.
#
# IT USED TO SAY "ONE PACKAGE", and the change is worth explaining because it
# looks like the rule being weakened. One BUILD may now produce two archives:
# <name> with what a printer runs and <name>-dev with the headers and static
# library only a build machine opens (PKG_DEV_FILES). That is one source, one
# configure, one version, sorted afterwards -- not the thing the rule forbids,
# which is one script compiling several different projects. The invariant that
# actually catches that is countable and unchanged: exactly one source verb
# per recipe.
#
# WHAT A RECIPE LOOKS LIKE:
#
#     . bin/common.sh
#     . pkg/lib.sh
#     pkg_begin libsodium || exit 0
#     pkg_toolchain
#     pkg_deps
#     pkg_unpack "$SODIUM_TGZ"
#     pkg_autotools "libsodium-$SODIUM_VERSION" "$MODDIR" "$PWD/$PKG_WORK/stage" \
#         --disable-static --enable-shared
#     pkg_ship "lib/libsodium.so*"
#     pkg_end
#
# Everything else -- the version, the dependencies, the package metadata --
# lives in the recipe's pkg.conf, which is the ONE place that describes a
# package. pkg_begin reads it, so the build and the packaging cannot disagree
# about what is being built.
#
# ONE TOOLCHAIN. Everything this repo cross-compiles uses the Ingenic glibc
# 2.29 / gcc 7.2 toolchain that produces this printer's ABI. There were two for
# a while -- skalibs, s6 and opkg were built against a Bootlin musl toolchain
# because a STATIC glibc s6 tree measured 73MB -- and that comparison never
# considered a DYNAMIC one, which is a few hundred KB and links the same
# libc.so.6 the interpreter already links. Two libcs also meant two of every
# library that both worlds wanted, which is not a thing a package feed can
# express without lying about one of them.
#
# SOURCED BY bin/patch.sh, for pkg_out alone -- it stages what recipes built
# and has to be able to name where they put it. It does NOT use the rest:
# section 5c still carries its own copy of the toolchain setup, the wrappers
# and the cross-build for CPython, and will until phase 1 of
# docs/notes/85-packaging.md turns that into recipes too. Claiming otherwise
# would be claiming the duplication is already gone.

# Recipes run as their own process (bin/patch.sh and bin/build-packages.sh both
# exec them rather than sourcing them), which is why nothing below bothers with
# the subshell that section 5c wraps its build in: the process boundary already
# guarantees no cross-compiler PATH or CC leaks into whatever runs next. That
# was the subshell's whole job.

pkg_say()  { printf '>> %s\n' "$*"; }
pkg_skip() { printf '   (skip) %s\n' "$*"; }
pkg_die()  { printf '   !! %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------- pkg_conf
#
#     pkg_conf <recipe-id>
#
# Read pkg/<id>/pkg.conf into the PKG_* metadata variables, defaults first so
# a recipe only spells what is true about it. Sets no build state -- every
# variable it touches is metadata, so pkg_begin can call it in the recipe's own
# shell while pkg_stamp calls it inside a subshell to look at somebody else's.
#
# PKG_BUILD_DEPENDS is recipe ids and never reaches the control file; it drives
# build order and pkg_deps. PKG_DEPENDS is what opkg reads at install time.
# Keeping them apart is what stops a package from declaring a runtime
# dependency on a library that was only ever linked into it.
#
# PKG_STAMP_EXTRA is for a recipe whose inputs are not described by its version
# number. Every recipe here builds a pinned tarball, so version-and-toolchain
# says everything -- except anvil-core, whose sources are files in this repo
# that change without any version changing. It puts a content hash there and
# pkg_stamp folds it in; see pkg/anvil-core/pkg.conf.
#
# PKG_DEV_FILES SPLITS ONE BUILD INTO TWO PACKAGES. A library that is both
# linked against and run -- execline, s6 -- produces headers and a static
# archive that only a build machine wants, alongside binaries a printer needs.
# Listing the first kind here moves it into a second package, <name>-dev,
# section libdevel, which nothing installs on a printer and which pkg_deps
# unpacks into a sysroot when the next recipe builds against it.
#
# THIS IS NOT "one recipe, two packages" IN THE SENSE THE RULE FORBIDS. The
# rule exists to stop one script building several different upstream projects
# -- zlib compiled inside the opkg recipe, which is what this whole layout
# replaced. A dev split is one source, one configure, one version, one build,
# sorted into two archives afterwards. Every distro does it and nothing about
# it lets a library go unversioned. The countable invariant is unchanged: one
# source verb per recipe.
#
# PKG_WHEN is a shell condition deciding whether this recipe exists at all.
# Mainsail, Moonraker and HelixScreen are downloads gated by BUILD_* flags, and
# a build configured without one has no source for it to unpack. Empty means
# always. A recipe whose condition is false is not a failure, it is absent:
# pkg_recipes does not list it, so nothing orders it, builds it or expects it
# in the feed.
pkg_conf() {
    PKG_NAME=''; PKG_VERSION=''; PKG_RELEASE=1; PKG_SECTION=libs
    PKG_ROOT=''; PKG_EXCLUDE=''; PKG_DEPENDS=''; PKG_BUILD_DEPENDS=''
    PKG_DESCRIPTION=''; PKG_ARCH="$IPK_ARCH"
    PKG_MAINTAINER='anvil <none@example.invalid>'
    PKG_STAMP_EXTRA=''; PKG_WHEN=''
    PKG_DEV_FILES=''; PKG_DEV_DESCRIPTION=''
    [ -f "$ROOT/pkg/$1/pkg.conf" ] || pkg_die "no recipe pkg/$1/pkg.conf"
    # shellcheck disable=SC1090
    . "$ROOT/pkg/$1/pkg.conf"
    PKG_ROOT="${PKG_ROOT:-$(pkg_out "$1")}"
}

# Where a recipe's build output lives, derived rather than named. Adding a
# package is then one directory under pkg/ and no edit to bin/common.sh --
# which is not tidiness: the three schemes this replaced (work/.sodium named by
# hand, work/.pkg-$id derived, work/.ipk-$name derived differently) all
# described the same recipe.
pkg_out() { printf '%s/work/pkg/%s' "$ROOT" "$1"; }

# The .ipk bin/build-packages.sh will write for a recipe, spelled the way
# opkg-build spells it: name_version-release_arch.ipk.
pkg_ipk() {
    ( pkg_conf "$1"
      printf '%s/%s%s_%s-%s_%s.ipk' \
          "$PKG_FEED" "$PKG_NAME" "${2:+-$2}" \
          "$PKG_VERSION" "$PKG_RELEASE" "$PKG_ARCH" )
}

# ---------------------------------------------------------------- pkg_stamp
#
# The cache key for a recipe: its own version, the toolchain that determines
# its ABI, and -- recursively -- the stamp of everything it builds against. A
# zlib bump therefore rebuilds libarchive and opkg without anybody maintaining
# a composite stamp by hand, which is what OPKG_STAMP used to be and what
# bin/fetch-assets.sh used to get wrong.
#
# THE TOOLCHAIN FILENAME IS IN THE STAMP because the compiler determines the
# ABI as much as the sources do, and a tree built by the toolchain this
# replaced has to be invalidated rather than reused. That is the failure that
# shipped once; see versions.env.
#
# Computed from pkg.conf alone, so bin/fetch-assets.sh can ask whether a build
# is going to need a compiler before any compiler exists.
pkg_stamp() {
    (
        _PKG_DEPTH=$(( ${_PKG_DEPTH:-0} + 1 ))
        export _PKG_DEPTH
        [ "$_PKG_DEPTH" -le 16 ] \
            || pkg_die "pkg_stamp: dependency cycle reached '$1'"
        pkg_conf "$1"
        _s="$1 $PKG_VERSION-$PKG_RELEASE $MIPS_TOOLCHAIN_FILE"
        # A recipe whose inputs are not its version number says so here. The
        # extra goes in BEFORE the dependency stamps so the string still reads
        # outermost-first when a human has to compare two of them by eye.
        [ -z "$PKG_STAMP_EXTRA" ] || _s="$_s $PKG_STAMP_EXTRA"
        for _d in $PKG_BUILD_DEPENDS; do
            _s="$_s [$(pkg_stamp "$_d")]"
        done
        printf '%s' "$_s"
    )
}

# True when a recipe's output tree is missing or was built from other inputs.
pkg_stale() {
    [ "$(cat "$(pkg_out "$1")/.version" 2>/dev/null || true)" != "$(pkg_stamp "$1")" ]
}

# Every recipe under pkg/, one per line. pkg.conf is what makes a directory a
# recipe -- build.sh alone is not enough, because a package with no metadata
# cannot be built into anything.
pkg_recipes() {
    for _d in "$ROOT"/pkg/*/; do
        [ -f "$_d/pkg.conf" ] || continue
        _r=$(basename "$_d")
        # PKG_WHEN in a subshell, because it is arbitrary shell out of a
        # recipe's metadata and this function is called by the fetcher, by the
        # packager and by the tests. A condition that set a variable or cd'd
        # somewhere would otherwise do it to whoever asked.
        ( pkg_conf "$_r"; [ -z "$PKG_WHEN" ] || eval "$PKG_WHEN" ) || continue
        printf '%s\n' "$_r"
    done
}

# True when anything under pkg/ needs compiling. This is what
# bin/fetch-assets.sh asks before pulling the ~203MB toolchain, instead of
# comparing a hand-written stamp string it has to keep in step with the builder
# -- the two spellings drifted, the comparison could never be false, and the
# toolchain was re-hashed on every single run for months.
pkg_needs() {
    for _r in $(pkg_recipes); do
        if pkg_stale "$_r"; then return 0; fi
    done
    return 1
}

# ---------------------------------------------------------------- pkg_order
#
#     pkg_order <recipe-id>...
#
# The given recipes and everything they build against, in an order where a
# dependency always precedes its dependent. Depth-first, so asking for one
# recipe gets its whole closure -- `PKG=opkg make packages` builds zlib and
# libarchive first rather than failing on an empty sysroot.
#
# Alphabetical order, which is what iterating pkg/*/ gives you, is wrong the
# moment there are two recipes: it puts libarchive before zlib.
pkg_order() {
    _order=''; _seen=' '; _path=' '
    for _r in "$@"; do _pkg_visit "$_r"; done
    printf '%s' "${_order# }"
}

_pkg_visit() {
    case "$_seen" in *" $1 "*) return 0 ;; esac
    # A cycle is a recipe reachable from itself. Reported by name rather than
    # by recursion depth, because the name is the thing somebody has to fix.
    case "$_path" in
        *" $1 "*) pkg_die "pkg_order: dependency cycle through '$1'" ;;
    esac
    _path="$_path$1 "
    for _d in $( ( pkg_conf "$1"; printf '%s' "$PKG_BUILD_DEPENDS" ) ); do
        _pkg_visit "$_d"
    done
    _path="${_path% "$1" }"
    _seen="$_seen$1 "
    _order="$_order $1"
}

# ---------------------------------------------------------------- pkg_begin
#
#     pkg_begin <recipe-id>
#
# Read the recipe's metadata, check the cache, and lay out the scratch tree.
# Returns non-zero when the output is already current, so every recipe starts
# `pkg_begin <id> || exit 0` and a warm tree costs one process spawn.
pkg_begin() {
    PKG_ID=$1
    pkg_conf "$PKG_ID"
    PKG_OUT=$PKG_ROOT
    PKG_STAMP=$(pkg_stamp "$PKG_ID")
    PKG_WORK="work/.pkg-$PKG_ID"

    if [ "$(cat "$PKG_OUT/.version" 2>/dev/null || true)" = "$PKG_STAMP" ]; then
        pkg_skip "$PKG_ID: $PKG_OUT already holds this build"
        return 1
    fi
    # "building", not "cross-building": since the asset packages landed, not
    # every recipe here runs a compiler, and a line that says otherwise about
    # a zip of JavaScript is a small lie in the one place a reader looks to
    # find out what a build actually did.
    pkg_say "$PKG_ID: building $PKG_NAME $PKG_VERSION-$PKG_RELEASE"
    rm -rf "$PKG_WORK" "$PKG_OUT"
    # src/  unpacked sources        stage/   DESTDIR of the install
    # xw/   compiler wrappers       sysroot/ build dependencies, unpacked
    # dep/  where opkg-unbuild drops them before they are merged into sysroot/
    mkdir -p "$PKG_WORK/src" "$PKG_WORK/stage" "$PKG_WORK/xw/bin" \
             "$PKG_WORK/sysroot" "$PKG_WORK/dep"
    PKG_SYSROOT="$PWD/$PKG_WORK/sysroot"
    PKG_LOG="$PWD/$PKG_WORK"
    # pkg_build's knobs, reset here so a recipe starts from the common case and
    # only spells what is unusual about its project. See pkg_build.
    PKG_CONFIGURE='./configure'; PKG_CONFIGURE_AUTO=1
    PKG_MAKE_TARGET=''; PKG_INSTALL_TARGET='install'; PKG_MAKE_ARGS=''
    return 0
}

# Seal the cache. Called last; anything that exits before it leaves no stamp,
# so a build interrupted halfway is rebuilt rather than believed.
pkg_end() {
    rm -rf "$PKG_WORK/src" "$PKG_WORK/stage" "$PKG_WORK/xw" \
           "$PKG_WORK/sysroot" "$PKG_WORK/dep"
    echo "$PKG_STAMP" > "$PKG_OUT/.version"
    pkg_say "$PKG_ID: $PKG_OUT sealed"
}

# ------------------------------------------------------------ pkg_toolchain
#
# Unpack the toolchain if it is not already there, write the compiler
# wrappers, put them on PATH, and then PROVE the wrappers produce the ABI this
# printer's kernel will actually exec.
#
# -mnan=2008 and -EL are baked into the compiler DRIVER rather than passed in
# CFLAGS, because autotools link lines do not all forward CFLAGS to the link
# step and a single object linked without them poisons the whole binary's ABI
# flags.
pkg_toolchain() {
    PKG_HOST=$PY_HOST
    PKG_TC=$PY_TOOLCHAIN_DIR
    PKG_CC_FLAGS='-EL -mnan=2008'

    if [ ! -x "$PKG_TC/bin/$PKG_HOST-gcc" ]; then
        [ -f "${MIPS_TOOLCHAIN_TGZ:-}" ] || pkg_die \
            "$PKG_ID needs the toolchain and '${MIPS_TOOLCHAIN_TGZ:-}' is missing. Run ./bin/fetch-assets.sh."
        pkg_say "$PKG_ID: unpacking the toolchain"
        mkdir -p work/.mips-toolchain
        tar -xf "$MIPS_TOOLCHAIN_TGZ" -C work/.mips-toolchain
        [ -x "$PKG_TC/bin/$PKG_HOST-gcc" ] \
            || pkg_die "the toolchain archive did not unpack $PKG_TC/bin/$PKG_HOST-gcc"
    fi

    PKG_XW="$PWD/$PKG_WORK/xw"
    _tc="$PWD/$PKG_TC"
    for _t in gcc g++ cpp; do
        printf '#!/bin/sh\nexec %s/bin/%s-%s %s "$@"\n' \
            "$_tc" "$PKG_HOST" "$_t" "$PKG_CC_FLAGS" > "$PKG_XW/bin/$PKG_HOST-$_t"
        chmod +x "$PKG_XW/bin/$PKG_HOST-$_t"
    done
    for _t in ar as ld nm objcopy objdump ranlib readelf strip strings size; do
        ln -sf "$_tc/bin/$PKG_HOST-$_t" "$PKG_XW/bin/$PKG_HOST-$_t"
    done
    export PATH="$PKG_XW/bin:$PATH"

    # THE CROSS TOOLS ARE EXPORTED, not just put on PATH, and that is not
    # belt-and-braces -- it is the difference between one mechanism and two.
    #
    # An autoconf configure finds the cross compiler from --host: it looks for
    # $host-gcc on PATH and that is the whole handshake. OpenSSL takes no
    # --host -- it takes a target NAME, linux-mips32 -- and reads $CC from the
    # environment, so with PATH alone it quietly used the build machine's gcc
    # and produced x86-64 objects. mips_abi_gate caught it at the package
    # boundary, which is the only reason this is a comment and not a shipped
    # library.
    #
    # Setting both means every project gets the toolchain the same way,
    # whether it asks by --host or by CC. They agree with each other because
    # they name the same wrappers, so nothing is ambiguous about which
    # compiler a build used.
    export CC="$PKG_HOST-gcc"     CXX="$PKG_HOST-g++"
    export AR="$PKG_HOST-ar"      RANLIB="$PKG_HOST-ranlib"
    export STRIP="$PKG_HOST-strip" NM="$PKG_HOST-nm"
    export OBJCOPY="$PKG_HOST-objcopy" OBJDUMP="$PKG_HOST-objdump"
    export LD="$PKG_HOST-ld"

    PKG_STRIP="$_tc/bin/$PKG_HOST-strip"

    # THE WRAPPER IS GATED BEFORE ANYTHING IS BUILT ON IT. A wrapper that
    # silently lost -mnan=2008 produces a tree that compiles, links, passes
    # every test on the build host and is refused by the printer's kernel at
    # exec(). Cheaper to find out here, from one hello-world, than from the
    # gate over a finished tree -- and far cheaper than from a printer.
    echo 'int main(void){return 0;}' > "$PKG_WORK/src/.abi.c"
    "$PKG_HOST-gcc" "$PKG_WORK/src/.abi.c" -o "$PKG_WORK/src/.abi.out" \
        || pkg_die "the $PKG_ID compiler wrapper cannot build a hello-world"
    _abi=$("$PKG_HOST-readelf" -h "$PKG_WORK/src/.abi.out" | awk '/Flags:/{print $2}' | tr -d ,)
    case "$_abi" in
        0x70001405|0x70001407) ;;
        *) pkg_die "the $PKG_ID compiler wrapper produces e_flags=$_abi, want 0x70001405 or 0x70001407" ;;
    esac
    pkg_say "$PKG_ID: toolchain ready ($PKG_HOST, e_flags=$_abi)"
}

# ----------------------------------------------------------------- pkg_deps
#
# Fill the recipe's sysroot from the feed: every recipe named in
# PKG_BUILD_DEPENDS is unpacked out of its own .ipk and merged in, then the
# usual cross-build variables are pointed at the result.
#
# UNPACKED BY opkg-unbuild, which is upstream's exact inverse of the
# opkg-build that made the file. Using it here is what lets opkg be an
# ordinary recipe rather than a bootstrap stage: nothing needs a working opkg
# in order to build packages, so nothing has to be built before anything else
# for any reason except its own declared dependencies.
#
# BUILDING AGAINST THE PACKAGE AND NOT AGAINST THE BUILD TREE is the point of
# the exercise. Pointing at work/pkg/zlib directly would be shorter and would
# work; it would also mean nothing ever checks that the .ipk contains the
# headers its dependents need. Here a package that forgot to ship a header
# fails the next recipe's configure, on the build that produced it.
#
# The sysroot mirrors the printer: dependencies live under $MODDIR inside it,
# exactly where they will live on the machine, which is why
# PKG_CONFIG_SYSROOT_DIR is set to the sysroot rather than emptied. The .pc
# files say prefix=/usr/data/anvil, and that variable is what turns their -I
# and -L into paths that exist here.
pkg_deps() {
    [ -n "$PKG_BUILD_DEPENDS" ] || return 0
    for _d in $PKG_BUILD_DEPENDS; do
        # BOTH HALVES OF THE DEPENDENCY, when it has two. A library that is
        # linked against and also run is packaged twice: <name> carries the
        # binaries a printer needs and <name>-dev the headers and the archive
        # a build machine needs. Which of the two exists is the dependency's
        # business, not ours -- a pure-dev library like anvil-zlib-dev has no
        # runtime half at all -- so both are tried and it is an error only if
        # NEITHER is there.
        _found=0
        for _v in '' dev; do
            _ipk=$(pkg_ipk "$_d" "$_v")
            [ -f "$_ipk" ] || continue
            _found=1
            _un="$PKG_WORK/dep/$_d${_v:+-$_v}"
            rm -rf "$_un"; mkdir -p "$_un"
            ( cd "$_un" && "$OPKG_UNBUILD_BIN" "$_ipk" ) \
                > "$PKG_LOG/$_d${_v:+-$_v}-unbuild.log" 2>&1 \
                || pkg_die "$PKG_ID: could not unpack $_ipk -- see $PKG_WORK/$_d${_v:+-$_v}-unbuild.log"
            # opkg-unbuild names the directory after the file it came from, and
            # drops CONTROL/ beside the payload. Only the payload is a sysroot.
            _payload="$_un/$(basename "$_ipk" .ipk)$MODDIR"
            [ -d "$_payload" ] || pkg_die \
                "$PKG_ID: $_d unpacked nothing under $MODDIR -- is it built for this prefix?"
            mkdir -p "$PKG_SYSROOT$MODDIR"
            cp -a "$_payload/." "$PKG_SYSROOT$MODDIR/"
            pkg_say "$PKG_ID: sysroot += $_d${_v:+-$_v}"
        done
        [ "$_found" = 1 ] || pkg_die \
            "$PKG_ID builds against '$_d' and neither $(pkg_ipk "$_d") nor $(pkg_ipk "$_d" dev) exists -- build it first (./bin/build-packages.sh $_d)"
    done

    _inc="$PKG_SYSROOT$MODDIR/include"
    _lib="$PKG_SYSROOT$MODDIR/lib"
    export CPPFLAGS="-I$_inc ${CPPFLAGS:-}"
    export LDFLAGS="-L$_lib ${LDFLAGS:-}"
    export PKG_CONFIG_PATH="$_lib/pkgconfig"
    export PKG_CONFIG_LIBDIR="$_lib/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$PKG_SYSROOT"
}

# ------------------------------------------------------------ source verbs
#
# A recipe names where its inputs come from EXACTLY ONCE, with one of the two
# verbs below. That is not a style rule: "one recipe builds one package" is
# checked by counting these calls (qa/static/test_ipk.py), and a recipe that
# unpacked two sources would be building somebody else's package inside its
# own -- the shape this whole layout replaced.
#
# --------------------------------------------------------------- pkg_unpack
#
#     pkg_unpack <archive>
#
# Extract this recipe's one pinned source archive into $PKG_WORK/src.
#
# ZIP AS WELL AS TAR, dispatched on the name. Mainsail publishes a .zip and
# everything else a tarball, and the alternative -- a second source verb, or an
# `unzip` line in the one recipe that needs it -- would either double the thing
# being counted or put an extraction command back in a recipe. tar reads its
# own compression off the file, so only the container needs deciding here.
pkg_unpack() {
    [ -f "${1:-}" ] || pkg_die "no source at '${1:-}' -- run ./bin/fetch-assets.sh"
    case "$1" in
        *.zip)
            command -v unzip >/dev/null 2>&1 \
                || pkg_die "$PKG_ID needs unzip to unpack $(basename "$1")"
            unzip -q -o "$1" -d "$PKG_WORK/src" \
                || pkg_die "$PKG_ID: could not unzip $1" ;;
        *)
            tar -xf "$1" -C "$PKG_WORK/src" \
                || pkg_die "$PKG_ID: could not untar $1" ;;
    esac
}

# --------------------------------------------------------------- pkg_intree
#
#     pkg_intree
#
# This recipe's sources are the checked-out repository, not a download.
#
# ONE RECIPE USES THIS AND IT IS anvil-core, whose contents are payload/ and
# assets/ -- files that are edited in this repo rather than fetched from
# anywhere. It unpacks nothing and exists for two reasons: so that "a recipe
# names its source exactly once" stays a countable property rather than one
# with an exemption, and so that reading the recipe tells you where its inputs
# are. The freshness of those inputs is PKG_STAMP_EXTRA's job, not this verb's.
pkg_intree() {
    PKG_SRC="$ROOT"
    pkg_say "$PKG_ID: source is this checkout, at $ROOT"
}

# ----------------------------------------------------------------- pkg_stage
#
#     pkg_stage <src> <dest-relative-to-prefix>
#
# Put a file or tree into the staged install, where pkg_ship expects to find
# it: $PKG_WORK/stage$MODDIR/<dest>.
#
# THIS IS `make install` FOR THINGS THAT HAVE NO make. Mainsail is a zip of
# static files, Moonraker is a python tree, HelixScreen is somebody else's
# prebuilt tarball and anvil-core is this repo's own scripts. None of them has
# a configure, a Makefile or a DESTDIR, but all of them still have to arrive
# somewhere before pkg_ship copies them out -- and staging into the same place
# an autotools install lands means pkg_ship, the .la sweep, the archive
# normalisation and the ELF-only strip all keep working with no special case
# for a package that was never compiled.
#
# cp -a, for the reason it is used everywhere else here: these trees contain
# symlinks and modes that are part of what is being shipped.
pkg_stage() {
    [ -e "${1:-}" ] || pkg_die "$PKG_ID: nothing to stage at '${1:-}'"
    [ -n "${2:-}" ] || pkg_die "$PKG_ID: pkg_stage needs a destination"
    _dst="$PKG_WORK/stage$MODDIR/$2"
    mkdir -p "$(dirname "$_dst")"
    cp -a "$1" "$_dst" || pkg_die "$PKG_ID: could not stage $1 -> $2"
}

# ---------------------------------------------------------------- pkg_build
#
#     pkg_build <srcdir-under-src> [configure args...]
#
# Configure, make, install into the staging tree. This is the ONLY way a
# recipe compiles anything.
#
# IT USED TO BE FOUR MECHANISMS AND THAT WAS THE BUG. There was pkg_autotools
# for projects with an autoconf configure; a hand-written ./configure line in
# pkg/zlib, sanctioned by a carve-out in the test that forbids every other
# recipe from doing the same; a pkg_make for bzip2, which has no configure at
# all; and a pkg_build for OpenSSL, whose configure is ./Configure and takes a
# target name instead of --host. Three of those four had exactly one user.
#
# One verb with one user is not a verb, it is an exception with a function
# name. The projects do not actually differ in four ways -- they differ in
# four SETTINGS of the same three steps -- so the settings are variables and
# the steps are written once.
#
#   PKG_CONFIGURE       the configure program.        default ./configure
#                       'none' skips the step entirely (bzip2).
#   PKG_CONFIGURE_AUTO  1 = prepend --host and --prefix, which is what an
#                       autoconf configure wants and what zlib and OpenSSL
#                       both refuse. default 1; set 0 and pass your own.
#   PKG_MAKE_TARGET     what to build.                default: everything
#   PKG_INSTALL_TARGET  how to install it.            default install
#                       'none' means the recipe places the files itself,
#                       because the project has no install target worth using.
#   PKG_MAKE_ARGS       extra variables for make (LDLIBS=-lpthread for s6).
#
# The prefix is always $MODDIR and the DESTDIR is always the recipe's staging
# tree -- every call site passed exactly those two values, so they were two
# arguments that could only ever be spelled one way.
#
# RETURNS NON-ZERO, NEVER DIES. Under the `set -euo pipefail` every recipe
# runs, a failure aborts the build anyway, so the common case reads the same
# as it did. What this buys is the uncommon one: OpenSSL's mips target
# hardcodes -mips2 and this toolchain defaults to -mfp64, a combination gcc
# refuses, and the recovery is to reconfigure for portable C. `if ! pkg_build`
# expresses that; a verb that called pkg_die could not.
pkg_build() {
    _dir=$1; shift
    _tag=$(basename "$_dir")
    _dest="$PWD/$PKG_WORK/stage"
    (
        set -e
        cd "$PKG_WORK/src/$_dir"

        # THE TRAILING ARGUMENTS GO TO WHICHEVER STEP CONSUMES THEM: to
        # configure when there is one, to make when there is not. bzip2 is why
        # this is spelled out -- it has no configure, so its CC/AR/RANLIB have
        # to reach make, and an earlier version of this verb dropped them on
        # the floor and built the library with the BUILD MACHINE's compiler.
        # It produced a perfectly good x86 archive and mips_abi_gate caught it
        # at the package boundary, which is the only reason this comment is
        # about a fixed bug rather than a shipped one.
        if [ "${PKG_CONFIGURE:-./configure}" != none ]; then
            if [ "${PKG_CONFIGURE_AUTO:-1}" = 1 ]; then
                set -- --host="$PKG_HOST" --prefix="$MODDIR" "$@"
            fi
            "${PKG_CONFIGURE:-./configure}" "$@" \
                > "$PKG_LOG/$_tag-configure.log" 2>&1
            set --
        fi

        # shellcheck disable=SC2086
        make -j"$(nproc 2>/dev/null || echo 4)" ${PKG_MAKE_TARGET:-} ${PKG_MAKE_ARGS:-} "$@" \
            > "$PKG_LOG/$_tag-make.log" 2>&1

        if [ "${PKG_INSTALL_TARGET:-install}" != none ]; then
            # shellcheck disable=SC2086
            make "${PKG_INSTALL_TARGET:-install}" DESTDIR="$_dest" ${PKG_MAKE_ARGS:-} \
                >> "$PKG_LOG/$_tag-make.log" 2>&1
        fi
    ) || {
        printf '   !! %s: building %s failed -- see %s\n' \
            "$PKG_ID" "$_tag" "$PKG_WORK/$_tag-{configure,make}.log" >&2
        return 1
    }
    pkg_say "$PKG_ID: built $_tag"
}

# --------------------------------------------------------------- pkg_ship
#
#     pkg_ship <relative-glob> [...]
#
# Copy what the package contains out of the staged install and into $PKG_OUT,
# which is the tree bin/build-packages.sh packages and bin/patch.sh stages.
# Globs are relative to the prefix inside the DESTDIR.
#
# cp -a and never plain cp: a shared library is three names, two of which are
# symlinks, and the first of those is the one libnacl's dlopen fallback
# constructs. A copy that dereferenced them would ship three identical copies
# of the same object and still work, until someone wondered why the payload had
# grown.
#
# WHAT A PACKAGE CONTAINS DEPENDS ON WHAT IT IS FOR. A library that ships to
# the printer ships its .so and nothing else. A library that exists to be built
# against -- zlib, libarchive, skalibs -- ships its headers, its .a and its .pc,
# because that is what the next recipe's configure has to find in the sysroot.
# Neither is the default; each recipe says which it is by what it passes here.
#
# PKG_STRIP_ARGS is --strip-unneeded by default, which keeps the dynamic
# symbols anything is going to dlsym out of a shared library. A recipe shipping
# executables can set it empty for a plain strip-all. Static archives and text
# files are never stripped: strip on a .a removes symbols the linker still
# needs, and there is nothing in a header to remove.
pkg_ship() {
    for _g in "$@"; do
        _dstdir="$PKG_OUT/$(dirname "$_g")"
        mkdir -p "$_dstdir"
        _n=0
        # Deliberately unquoted: $_g is a glob and this is where it expands.
        # The loop no longer uses `set --` to do it -- that worked, but it
        # destroyed the function's own positional parameters as a side effect,
        # which is a trap laid for whoever next adds a line after this loop.
        for _m in $PKG_WORK/stage$MODDIR/$_g; do
            [ -e "$_m" ] || continue
            cp -a "$_m" "$_dstdir/"
            _n=$((_n + 1))
        done
        [ "$_n" -gt 0 ] || pkg_die "$PKG_ID: nothing matched '$_g' in the staged install"
    done
    # .la files name absolute build-machine paths and are useless to anything
    # that links against a package rather than against a build tree.
    find "$PKG_OUT" -name '*.la' -delete

    # STATIC ARCHIVES ARE NOT REPRODUCIBLE UNTIL THEY ARE MADE SO. An ar
    # archive stores, per member, an mtime and the uid/gid of whoever ran the
    # compiler, and the symbol index carries a timestamp of its own. Measured:
    # two cold builds of pkg/zlib an hour apart produced .ipk files with
    # different sha256, and every member read "1000/1000 Aug 28 15:10". So the
    # package would differ between two builds of one tree, and between two
    # developers' accounts on the same commit -- which is the exact problem
    # opkg-build's `-o 0 -g 0` was already being passed to solve one layer up.
    # bin/build-packages.sh sets SOURCE_DATE_EPOCH and opkg-build clamps the
    # tarballs, and none of that reaches inside a .a.
    #
    # TWO TOOLS, AND THE SPLIT IS NOT ARBITRARY. An ar archive has two kinds of
    # timestamp: one in each member's header, and one in the header of the
    # symbol-index member that ranlib writes. They are normalised by different
    # switches, and this toolchain can only do the first.
    #
    #   objcopy -D   zeroes uid, gid and mtime in the MEMBER headers.
    #   ranlib  -D   rewrites the symbol INDEX with a zeroed header.
    #
    # The cross binutils is 2.27 (it ships with the gcc 7.2 Ingenic toolchain)
    # and its ranlib does not honour -D for the index: measured, it replaced
    # the old timestamp with the CURRENT one and the archive stayed
    # irreproducible. So the index is rewritten with the BUILD MACHINE's
    # ranlib, which is 2.40 in docker/Dockerfile.build and new enough. ar is a
    # container format and ranlib reads the members through BFD, so a modern
    # host binutils indexes mipsel objects correctly -- and the proof that it
    # does is downstream rather than asserted: opkg links against both of these
    # archives, and a broken index fails that link with undefined symbols.
    # BOTH PASSES BELOW NEED THE CROSS TOOLCHAIN, and a recipe that compiles
    # nothing never called pkg_toolchain, so there is none. Mainsail is a zip
    # of JavaScript, Moonraker is a python tree, anvil-core is this repo's own
    # shell scripts: no archive to normalise and no ELF to strip, and reaching
    # for $PKG_HOST-objcopy would fail on the variable rather than on anything
    # real. Skipping is safe because it is not the last word -- every package
    # goes through mips_abi_gate at the package boundary in
    # bin/build-packages.sh, which reads every ELF it can find. A recipe that
    # forgot pkg_toolchain and did produce objects is caught there, by the gate
    # whose job that is, instead of here by an unbound variable.
    if [ -n "${PKG_HOST:-}" ]; then
        find "$PKG_OUT" -name '*.a' -print | while IFS= read -r _a; do
            "$PKG_HOST-objcopy" --enable-deterministic-archives "$_a" \
                || pkg_die "$PKG_ID: could not normalise the member headers of $_a"
            ranlib -D "$_a" \
                || pkg_die "$PKG_ID: could not write a deterministic index for $_a"
        done

        find "$PKG_OUT" -type f -print | while IFS= read -r _f; do
            case "$_f" in *.a|*.h|*.pc|*.la) continue ;; esac
            # readelf is the ELF test, because it is the tool that has to
            # answer the question anyway and it exits non-zero on anything else.
            "$PKG_HOST-readelf" -h "$_f" >/dev/null 2>&1 || continue
            # Stripped with the CROSS strip; the host's would refuse a MIPS
            # object.
            # shellcheck disable=SC2086
            "$PKG_STRIP" ${PKG_STRIP_ARGS---strip-unneeded} "$_f" 2>/dev/null || true
        done
    fi
}
