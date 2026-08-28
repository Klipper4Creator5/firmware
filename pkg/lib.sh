# The part of a cross-build that is the same for every package.
#
# Sourced by pkg/*/build.sh, after bin/common.sh. Everything below was written
# twice already -- once in bin/patch.sh section 5b for s6 and once in 5d for
# libsodium -- before there was anywhere to put it, and the two copies had
# already drifted: 5b gates its own compiler wrapper before trusting it and 5d
# does not. That is the argument for this file in one sentence. A recipe should
# say what is different about its package and nothing else.
#
# WHAT A RECIPE LOOKS LIKE WITH THIS:
#
#     . bin/common.sh
#     . pkg/lib.sh
#     pkg_begin libsodium "$SODIUM_VERSION" "$SODIUM_BUILD" || exit 0
#     pkg_toolchain ingenic
#     pkg_unpack "$SODIUM_TGZ"
#     pkg_autotools "libsodium-$SODIUM_VERSION" "$MODDIR" "$PWD/$PKG_WORK/stage" \
#         --disable-static --enable-shared
#     pkg_ship "lib/libsodium.so*"
#     pkg_end
#
# THE TWO TOOLCHAINS ARE BOTH HERE ON PURPOSE. libsodium is dlopened by a glibc
# interpreter and must be Ingenic-glibc; opkg is a standalone binary that talks
# to nothing of ours and is musl-static, exactly like s6 and for the reason
# versions.env gives for s6. A shared build library that only handled one of
# them would be a library for libsodium with extra steps -- the second
# toolchain is what proves the seam is in the right place.
#
# NOT SOURCED BY bin/patch.sh. Sections 5b and 5c still carry their own copies
# of this logic and will until phase 1 of docs/notes/85-packaging.md turns them
# into recipes too. Claiming otherwise would be claiming the duplication is
# already gone.

# Recipes run as their own process (bin/patch.sh and bin/build-packages.sh both
# exec them rather than sourcing them), which is why nothing below bothers with
# the subshell that 5b, 5c and 5d each wrap their build in: the process
# boundary already guarantees no cross-compiler PATH or CC leaks into whatever
# runs next. That was the subshells' whole job.

pkg_say()  { printf '>> %s\n' "$*"; }
pkg_skip() { printf '   (skip) %s\n' "$*"; }
pkg_die()  { printf '   !! %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- pkg_begin
#
# The cache check, which is the first thing every recipe does and the reason
# bin/fetch-assets.sh can skip a 203MB download: the stamp inside the build
# tree names the version it was built from, and both the fetcher and the
# builder read it. Returns non-zero when the tree is already current, so a
# recipe's first line is `pkg_begin ... || exit 0`.
#
# STAMPED ON THE WHOLE INPUT, not just the package's own version. opkg is built
# against a libarchive and a zlib that are pinned separately, and an opkg
# rebuilt because libarchive moved is exactly the case a version-only stamp
# gets wrong -- it is the same argument bin/patch.sh's PY_STAMP makes for
# CPython's seven libraries. Recipes pass everything that goes into the tree.
pkg_begin() {
    PKG_ID=$1
    PKG_STAMP=$2
    PKG_OUT=$3
    PKG_WORK="work/.pkg-$PKG_ID"

    if [ "$(cat "$PKG_OUT/.version" 2>/dev/null || true)" = "$PKG_STAMP" ]; then
        pkg_skip "$PKG_ID: $PKG_OUT already holds $PKG_STAMP"
        return 1
    fi
    pkg_say "$PKG_ID: cross-building $PKG_STAMP"
    rm -rf "$PKG_WORK" "$PKG_OUT"
    # src/  unpacked sources        stage/  DESTDIR of the final install
    # xw/   compiler wrappers       sysroot/ where a recipe's own build-only
    #                                       dependencies install themselves
    mkdir -p "$PKG_WORK/src" "$PKG_WORK/stage" "$PKG_WORK/xw/bin" \
             "$PKG_WORK/sysroot"
    PKG_SYSROOT="$PWD/$PKG_WORK/sysroot"
    PKG_LOG="$PWD/$PKG_WORK"
    return 0
}

# Seal the cache. Called last; anything that exits before it leaves no stamp,
# so a build interrupted halfway is rebuilt rather than believed.
pkg_end() {
    rm -rf "$PKG_WORK/src" "$PKG_WORK/stage" "$PKG_WORK/xw" "$PKG_WORK/sysroot"
    echo "$PKG_STAMP" > "$PKG_OUT/.version"
    pkg_say "$PKG_ID: $PKG_OUT sealed at $PKG_STAMP"
}

# ------------------------------------------------------------ pkg_toolchain
#
#     pkg_toolchain ingenic     glibc 2.29 / gcc 7.2, for anything the
#                               printer's own python has to dlopen
#     pkg_toolchain musl        Bootlin mips32r5el musl, for standalone
#                               binaries that link against nothing of ours
#
# Unpacks the toolchain if it is not already there, writes the compiler
# wrappers, puts them on PATH, and then PROVES the wrappers produce the ABI
# this printer's kernel will actually exec. That last step is section 5b's and
# was missing from 5d; having one copy is how it stops being optional.
pkg_toolchain() {
    # Saved before anything else touches the positional parameters: the
    # Bootlin rename below uses `set --` to glob, which overwrites $1, and the
    # only symptom was a log line naming a directory where it meant to name a
    # toolchain.
    _kind=$1
    case "$_kind" in
    ingenic)
        # The Ingenic glibc toolchain. -mnan=2008 and -EL baked into the
        # driver rather than passed in CFLAGS, because autotools link lines do
        # not all forward CFLAGS to the link step and a single object linked
        # without them poisons the whole binary's ABI flags.
        PKG_HOST=$PY_HOST
        PKG_TC=$PY_TOOLCHAIN_DIR
        PKG_TC_TGZ=${MIPS_TOOLCHAIN_TGZ:-}
        PKG_TC_INTO=work/.mips-toolchain
        PKG_CC_FLAGS='-EL -mnan=2008'
        PKG_LINK_TEST=''
        ;;
    musl)
        # Bootlin's mips32r5el musl toolchain -- NOT mips32el, whose musl crt
        # is legacy-NaN by construction and cannot be made to emit nan2008 at
        # all. -march=mips32r2 restricts codegen back to what the silicon
        # actually implements. versions.env tells this story at length; it is
        # the mistake that shipped once.
        PKG_HOST=mipsel-buildroot-linux-musl
        PKG_TC=work/.musl-toolchain/$PKG_HOST-cross
        PKG_TC_TGZ=${MUSL_TOOLCHAIN_TGZ:-}
        PKG_TC_INTO=work/.musl-toolchain
        PKG_CC_FLAGS='-EL -mnan=2008 -march=mips32r2'
        # Everything built with this toolchain is linked static, so the ABI
        # self-test has to be too -- a dynamic test would prove the wrapper
        # works for a link mode nothing here uses.
        PKG_LINK_TEST='-static'
        ;;
    *) pkg_die "unknown toolchain '$1' (ingenic|musl)" ;;
    esac

    if [ ! -x "$PKG_TC/bin/$PKG_HOST-gcc" ]; then
        [ -f "$PKG_TC_TGZ" ] || pkg_die \
            "$PKG_ID needs the $_kind toolchain and '$PKG_TC_TGZ' is missing. Run ./bin/fetch-assets.sh."
        pkg_say "$PKG_ID: unpacking the $_kind toolchain"
        mkdir -p "$PKG_TC_INTO"
        # -xf and not -xzf: one of these is .tar.gz and the other .tar.xz, and
        # tar picks the decompressor off the file either way.
        tar -xf "$PKG_TC_TGZ" -C "$PKG_TC_INTO"
        if [ ! -x "$PKG_TC/bin/$PKG_HOST-gcc" ]; then
            # Bootlin's archive unpacks into a directory named after the
            # RELEASE, not after the triple, and the release string moves every
            # few months. It is the only thing the archive creates at top
            # level, so renaming whatever that turns out to be is what keeps
            # $PKG_TC out of the version business.
            set -- "$PKG_TC_INTO"/*/
            [ -d "$1" ] || pkg_die "the $PKG_ID toolchain archive unpacked no directory"
            mv "$1" "$PKG_TC"
        fi
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
    "$PKG_HOST-gcc" $PKG_LINK_TEST "$PKG_WORK/src/.abi.c" -o "$PKG_WORK/src/.abi.out" \
        || pkg_die "the $PKG_ID compiler wrapper cannot build a hello-world"
    _abi=$("$PKG_HOST-readelf" -h "$PKG_WORK/src/.abi.out" | awk '/Flags:/{print $2}' | tr -d ,)
    case "$_abi" in
        0x70001405|0x70001407) ;;
        *) pkg_die "the $PKG_ID compiler wrapper produces e_flags=$_abi, want 0x70001405 or 0x70001407" ;;
    esac
    pkg_say "$PKG_ID: $_kind toolchain ready ($PKG_HOST, e_flags=$_abi)"
}

# --------------------------------------------------------------- pkg_unpack
# Extract a pinned source tarball into $PKG_WORK/src.
pkg_unpack() {
    [ -f "${1:-}" ] || pkg_die "no source at '${1:-}' -- run ./bin/fetch-assets.sh"
    tar -xf "$1" -C "$PKG_WORK/src"
}

# ------------------------------------------------------------ pkg_autotools
#
#     pkg_autotools <srcdir-under-src> <prefix> <destdir> [configure args...]
#
# The ./configure && make && make install DESTDIR=... that every one of these
# packages is, with the two things that are easy to get wrong done once:
# --host is what makes autoconf reach for the $PKG_HOST-prefixed tools in the
# wrapper directory (the entire point of having written them), and the logs go
# to files because a failing cross-build prints thousands of lines and the
# useful twenty are never the last twenty.
#
# PKG_MAKE_ARGS, if the caller sets it, is passed to BOTH make invocations.
# It exists for one thing that cannot be done at configure time: a fully static
# link through libtool. libtool defines `-static` to mean "prefer the static
# copies of libtool libraries" and swallows it rather than handing it to gcc,
# so a program configured LDFLAGS=-static comes out dynamic anyway -- measured,
# and the only symptom is a NEEDED entry nobody looks at. The flag that means
# what it says is `-all-static`, and it cannot go through ./configure because
# configure's own link probes call gcc directly, which rejects it outright. So
# it goes to make, and it has to carry the -L flags configure would otherwise
# have supplied, because assigning LDFLAGS on the make command line replaces
# the configured value rather than adding to it.
pkg_autotools() {
    _dir=$1; _prefix=$2; _dest=$3; shift 3
    _tag=$(basename "$_dir")
    (
        set -e
        cd "$PKG_WORK/src/$_dir"
        ./configure --host="$PKG_HOST" --prefix="$_prefix" "$@" \
            > "$PKG_LOG/$_tag-configure.log" 2>&1
        make -j"$(nproc 2>/dev/null || echo 4)" ${PKG_MAKE_ARGS+"${PKG_MAKE_ARGS[@]}"} \
            > "$PKG_LOG/$_tag-make.log" 2>&1
        make install DESTDIR="$_dest" ${PKG_MAKE_ARGS+"${PKG_MAKE_ARGS[@]}"} \
            >> "$PKG_LOG/$_tag-make.log" 2>&1
    ) || pkg_die "$PKG_ID: building $_tag failed -- see $PKG_WORK/$_tag-configure.log and $PKG_WORK/$_tag-make.log (sources kept in $PKG_WORK/src)"
    pkg_say "$PKG_ID: built $_tag"
}

# Point every later configure in this recipe at what the earlier ones
# installed into its private sysroot. Called after each build-only dependency;
# idempotent, because a recipe with three of them calls it three times.
#
# PKG_CONFIG_SYSROOT_DIR is set EMPTY on purpose rather than left alone:
# without it pkg-config prefixes every -I and -L it reports with the build
# machine's own sysroot, and the flags then point at nothing. That failure
# looks like a missing library rather than a mangled path.
pkg_dep_paths() {
    export CPPFLAGS="-I$PKG_SYSROOT/include ${CPPFLAGS:-}"
    export LDFLAGS="-L$PKG_SYSROOT/lib ${LDFLAGS:-}"
    export PKG_CONFIG_PATH="$PKG_SYSROOT/lib/pkgconfig"
    export PKG_CONFIG_LIBDIR="$PKG_SYSROOT/lib/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR=""
}

# A build-only dependency: the same configure/make/install, but into the
# recipe's private sysroot instead of into the staging tree, so it is linked
# against and never shipped. opkg's zlib and libarchive are this; skalibs is
# the same shape for s6, which is where the pattern comes from.
pkg_dep_autotools() {
    _dir=$1; shift
    pkg_autotools "$_dir" "$PKG_SYSROOT" "" "$@"
    pkg_dep_paths
}

# --------------------------------------------------------------- pkg_ship
#
#     pkg_ship <relative-glob> [...]
#
# Copy what actually ships out of the staged install and into $PKG_OUT, which
# is the tree bin/build-packages.sh packages and bin/patch.sh stages. Globs are
# relative to the prefix inside the DESTDIR.
#
# cp -a and never plain cp: a shared library is three names, two of which are
# symlinks, and the first of those is the one libnacl's dlopen fallback
# constructs. A copy that dereferenced them would ship three identical copies
# of the same object and still work, until someone wondered why the payload
# had grown.
#
# WHAT IS DELIBERATELY LEFT BEHIND: include/, lib/pkgconfig and .la files.
# Headers and .pc files exist to BUILD against a library, which happens on a
# developer's machine and not on a printer. The .la files go for that reason
# plus one more -- they name absolute build-machine paths.
pkg_ship() {
    for _g in "$@"; do
        _src="$PKG_WORK/stage$MODDIR/$_g"
        # $_src is a glob and must be split and expanded here.
        # shellcheck disable=SC2086
        set -- $_src
        [ -e "$1" ] || pkg_die "$PKG_ID: nothing matched '$_g' in the staged install"
        _dstdir="$PKG_OUT/$(dirname "$_g")"
        mkdir -p "$_dstdir"
        cp -a "$@" "$_dstdir/"
    done
    find "$PKG_OUT" -name '*.la' -delete
    # Stripped with the CROSS strip. The host's would refuse a MIPS object,
    # and --strip-unneeded rather than -s so a shared library keeps the
    # dynamic symbols anything is going to dlsym out of it.
    find "$PKG_OUT" -type f -exec "$PKG_STRIP" --strip-unneeded {} + 2>/dev/null || true
}
