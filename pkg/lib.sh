# The part of a cross-build that is the same for every package.
#
# Sourced by pkg/*/build.sh, after bin/common.sh.
#
# ONE RECIPE BUILDS ONE PACKAGE. That is the rule this file exists to make
# cheap. A recipe unpacks one source, builds it, and ships it; anything it
# needs to build against arrives as a package that some other recipe produced,
# unpacked out of the feed by pkg_deps. The alternative -- a recipe that builds
# its own dependencies inline, which is what pkg/opkg used to do with zlib and
# libarchive, and what bin/patch.sh section 5b still does with skalibs -- makes
# every library an invisible detail of whoever needed it first: unversioned,
# unshippable, and rebuilt from scratch by the next consumer. zlib was the
# proof, cross-built twice in one tree.
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
# NOT SOURCED BY bin/patch.sh. Section 5c still carries its own copy of all of
# this for CPython, and will until phase 1 of docs/notes/85-packaging.md turns
# it into a recipe too. Claiming otherwise would be claiming the duplication is
# already gone.

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
pkg_conf() {
    PKG_NAME=''; PKG_VERSION=''; PKG_RELEASE=1; PKG_SECTION=libs
    PKG_ROOT=''; PKG_EXCLUDE=''; PKG_DEPENDS=''; PKG_BUILD_DEPENDS=''
    PKG_DESCRIPTION=''; PKG_ARCH="$IPK_ARCH"
    PKG_MAINTAINER='anvil <none@example.invalid>'
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
      printf '%s/%s_%s-%s_%s.ipk' \
          "$PKG_FEED" "$PKG_NAME" "$PKG_VERSION" "$PKG_RELEASE" "$PKG_ARCH" )
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
        [ -f "$_d/pkg.conf" ] && basename "$_d"
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
    pkg_say "$PKG_ID: cross-building $PKG_NAME $PKG_VERSION-$PKG_RELEASE"
    rm -rf "$PKG_WORK" "$PKG_OUT"
    # src/  unpacked sources        stage/   DESTDIR of the install
    # xw/   compiler wrappers       sysroot/ build dependencies, unpacked
    # dep/  where opkg-unbuild drops them before they are merged into sysroot/
    mkdir -p "$PKG_WORK/src" "$PKG_WORK/stage" "$PKG_WORK/xw/bin" \
             "$PKG_WORK/sysroot" "$PKG_WORK/dep"
    PKG_SYSROOT="$PWD/$PKG_WORK/sysroot"
    PKG_LOG="$PWD/$PKG_WORK"
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
        _ipk=$(pkg_ipk "$_d")
        [ -f "$_ipk" ] || pkg_die \
            "$PKG_ID builds against '$_d' and $_ipk is missing -- build it first (./bin/build-packages.sh $_d)"
        _un="$PKG_WORK/dep/$_d"
        rm -rf "$_un"; mkdir -p "$_un"
        ( cd "$_un" && "$OPKG_UNBUILD_BIN" "$_ipk" ) > "$PKG_LOG/$_d-unbuild.log" 2>&1 \
            || pkg_die "$PKG_ID: could not unpack $_ipk -- see $PKG_WORK/$_d-unbuild.log"
        # opkg-unbuild names the directory after the file it came from, and
        # drops CONTROL/ beside the payload. Only the payload is a sysroot.
        _payload="$_un/$(basename "$_ipk" .ipk)$MODDIR"
        [ -d "$_payload" ] || pkg_die \
            "$PKG_ID: $_d unpacked nothing under $MODDIR -- is it built for this prefix?"
        mkdir -p "$PKG_SYSROOT$MODDIR"
        cp -a "$_payload/." "$PKG_SYSROOT$MODDIR/"
        pkg_say "$PKG_ID: sysroot += $_d"
    done

    _inc="$PKG_SYSROOT$MODDIR/include"
    _lib="$PKG_SYSROOT$MODDIR/lib"
    export CPPFLAGS="-I$_inc ${CPPFLAGS:-}"
    export LDFLAGS="-L$_lib ${LDFLAGS:-}"
    export PKG_CONFIG_PATH="$_lib/pkgconfig"
    export PKG_CONFIG_LIBDIR="$_lib/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR="$PKG_SYSROOT"
}

# --------------------------------------------------------------- pkg_unpack
# Extract this recipe's one pinned source tarball into $PKG_WORK/src.
pkg_unpack() {
    [ -f "${1:-}" ] || pkg_die "no source at '${1:-}' -- run ./bin/fetch-assets.sh"
    tar -xf "$1" -C "$PKG_WORK/src"
}

# ------------------------------------------------------------ pkg_autotools
#
#     pkg_autotools <srcdir-under-src> <prefix> <destdir> [configure args...]
#
# The ./configure && make && make install DESTDIR=... that most of these
# packages are, with the two things that are easy to get wrong done once:
# --host is what makes autoconf reach for the $PKG_HOST-prefixed tools in the
# wrapper directory (the entire point of having written them), and the logs go
# to files because a failing cross-build prints thousands of lines and the
# useful twenty are never the last twenty.
pkg_autotools() {
    _dir=$1; _prefix=$2; _dest=$3; shift 3
    _tag=$(basename "$_dir")
    (
        set -e
        cd "$PKG_WORK/src/$_dir"
        ./configure --host="$PKG_HOST" --prefix="$_prefix" "$@" \
            > "$PKG_LOG/$_tag-configure.log" 2>&1
        make -j"$(nproc 2>/dev/null || echo 4)" > "$PKG_LOG/$_tag-make.log" 2>&1
        make install DESTDIR="$_dest" >> "$PKG_LOG/$_tag-make.log" 2>&1
    ) || pkg_die "$PKG_ID: building $_tag failed -- see $PKG_WORK/$_tag-configure.log and $PKG_WORK/$_tag-make.log (sources kept in $PKG_WORK/src)"
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
    find "$PKG_OUT" -name '*.a' -print | while IFS= read -r _a; do
        "$PKG_HOST-objcopy" --enable-deterministic-archives "$_a" \
            || pkg_die "$PKG_ID: could not normalise the member headers of $_a"
        ranlib -D "$_a" \
            || pkg_die "$PKG_ID: could not write a deterministic index for $_a"
    done

    find "$PKG_OUT" -type f -print | while IFS= read -r _f; do
        case "$_f" in *.a|*.h|*.pc|*.la) continue ;; esac
        # readelf is the ELF test, because it is the tool that has to answer
        # the question anyway and it exits non-zero on anything else.
        "$PKG_HOST-readelf" -h "$_f" >/dev/null 2>&1 || continue
        # Stripped with the CROSS strip; the host's would refuse a MIPS object.
        # shellcheck disable=SC2086
        "$PKG_STRIP" ${PKG_STRIP_ARGS---strip-unneeded} "$_f" 2>/dev/null || true
    done
}
