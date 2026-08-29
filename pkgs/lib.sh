# The part of a cross-build that is the same for every package.
#
# Sourced by every recipe's build.sh, after bin/common.sh.
#
# ONE RECIPE BUILDS ONE SOURCE: it unpacks one source, builds it, and ships it;
# anything it builds against arrives as a package another recipe produced,
# unpacked out of the feed by pkg_deps. The invariant is countable, and
# qa/static/test_ipk.py counts it: exactly one source verb per recipe. One
# build may still produce two archives -- <name> for the printer and <name>-dev
# for the headers a build machine opens (PKG_DEV_FILES) -- which is one source
# sorted into two archives afterwards, not one script compiling two projects.
#
# WHAT A RECIPE LOOKS LIKE:
#
#     . ./bin/common.sh
#     . pkgs/lib.sh
#     pkg_begin libsodium || exit 0
#     pkg_toolchain
#     pkg_deps
#     pkg_unpack "$SODIUM_TGZ"
#     pkg_build "libsodium-$SODIUM_VERSION" --disable-static --enable-shared
#     pkg_ship "lib/libsodium.so*"
#     pkg_end
#
# The version, the dependencies and the package metadata live in the recipe's
# pkg.conf, the one place that describes a package; pkg_begin reads it, so the
# build and the packaging cannot disagree about what is being built.
#
# ONE TOOLCHAIN: everything here cross-compiles with the Ingenic glibc 2.29 /
# gcc 7.2 toolchain that produces this printer's ABI. A second libc would mean
# two of every library both worlds wanted, which a package feed cannot express
# without lying about one of them.
#
# Also sourced by bin/patch.sh, for pkg_out alone -- it stages what recipes
# built and has to name where they put it.
#
# Recipes run as their own process (both bin/patch.sh and bin/build-packages.sh
# exec them), so no cross-compiler PATH or CC can leak into whatever runs next
# and nothing below needs a subshell to prevent it.

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
# pkg_stamp folds it in; see pkgs/anvil-core/pkg.conf.
#
# PKG_DEV_FILES splits one build into two packages: files listed here move
# into <name>-dev, section libdevel, which no printer installs and which
# pkg_deps unpacks into a sysroot when the next recipe builds against it.
#
# PKG_WHEN is a shell condition deciding whether this recipe exists at all
# (Mainsail, Moonraker and HelixScreen are downloads gated by BUILD_* flags).
# Empty means always. A false condition is absence, not failure: pkg_recipes
# does not list it, so nothing orders it, builds it or expects it in the
# feed.

# ------------------------------------------------------- pkg_payload_hash
#
#     PKG_STAMP_EXTRA="$(pkg_payload_hash)"
#
# Sixteen hex digits over every file in this recipe's payload/ -- the cache
# key for the half of a package that comes out of this checkout instead of out
# of a tarball. Called from pkg.conf, where $PKG_DIR is already set.
#
# WHY A RECIPE NEEDS THIS AT ALL. pkg_stamp is built from a version number,
# and a version number only describes an upstream. A recipe that also ships
# files of ours has inputs the version cannot see, and a stamp that cannot see
# an input does not fail -- it reports "already current" and hands over the
# previous build. That is exactly what was happening to helixscreen: its
# printer-database entry was hashed into ANVIL-CORE's stamp, so editing the
# json rebuilt a package that does not contain it and left the package that
# does sitting in the cache.
#
# It hashes payload/ and nothing else, because payload/ is what a recipe
# ships. prog/ and seed/ are placed by bin/patch.sh, are in no package, and
# must not invalidate one.
pkg_payload_hash() {
    find "$PKG_DIR/payload" -type f -print0 2>/dev/null \
        | LC_ALL=C sort -z | xargs -0 sha256sum 2>/dev/null \
        | sha256sum | cut -c1-16
}

# ------------------------------------------------------------------ pkg_dir
#
#     pkg_dir <recipe-id>      ->  the directory holding its pkg.conf
#
# Recipes live at two depths and this is the only function that knows it.
#
#     pkgs/<name>/            a recipe that carries FILES OF THIS REPO --
#                             a payload/, a prog/ or a seed/. Four of them.
#     pkgs/3rdparty/<name>/   a recipe that builds a pinned tarball and
#                             stages nothing from the checkout. Thirty-four.
#
# THE SPLIT IS MECHANICAL, NOT EDITORIAL, and that is the whole reason it can
# be a directory rather than a field. "Do we actively modify it" drifts: the
# day somebody patches zlib, is it still third-party? Whether a recipe carries
# files of ours is a fact about the tree, checkable in one assertion
# (qa/static/test_recipe_layout.py), and a recipe crossing the line is a move
# that the same test demands.
#
# What it buys is `ls pkgs/`: four entries that a person edits, instead of
# thirty-eight where the four are buried. Nothing else in this file, and
# nothing in any recipe, spells either path.
#
# Names are unique ACROSS both levels -- pkg_out, pkg_stamp and the .ipk
# filename are all keyed by the bare name -- and test_recipe_layout.py holds
# that too, because a duplicate would resolve to whichever level is searched
# first and build the wrong thing very quietly.
pkg_dir() {
    for _c in "$ROOT/pkgs/$1" "$ROOT/pkgs/3rdparty/$1"; do
        if [ -f "$_c/pkg.conf" ]; then printf '%s' "$_c"; return 0; fi
    done
    return 1
}

pkg_conf() {
    PKG_NAME=''; PKG_VERSION=''; PKG_RELEASE=1; PKG_SECTION=libs
    PKG_ROOT=''; PKG_EXCLUDE=''; PKG_DEPENDS=''; PKG_BUILD_DEPENDS=''
    PKG_PROVIDES=''; PKG_CONFLICTS=''
    PKG_DESCRIPTION=''; PKG_ARCH="$IPK_ARCH"
    PKG_MAINTAINER='anvil <none@example.invalid>'
    PKG_STAMP_EXTRA=''; PKG_WHEN=''
    PKG_DEV_FILES=''; PKG_DEV_DESCRIPTION=''
    # PKG_DIR IS SET BEFORE THE FILE IS SOURCED so that pkg.conf and build.sh
    # can name their own directory without either of them spelling out where
    # recipes live -- which is now two places, so nothing else should have to
    # know that.
    PKG_DIR=$(pkg_dir "$1") \
        || pkg_die "no recipe named '$1' under pkgs/ or pkgs/3rdparty/"
    # shellcheck disable=SC1090
    . "$PKG_DIR/pkg.conf"
    PKG_ROOT="${PKG_ROOT:-$(pkg_out "$1")}"
}

# Where a recipe's build output lives, derived rather than named, so adding a
# package is one directory under pkg/ and no edit to bin/common.sh.
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
# its ABI, and -- recursively -- the stamp of everything it builds against, so
# a zlib bump rebuilds libarchive and opkg with no composite stamp maintained
# by hand. The toolchain filename is in it because the compiler decides the ABI
# as much as the sources do, and a tree built by another one has to be
# invalidated rather than reused.
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
        # Before the dependency stamps, so the string still reads
        # outermost-first when two are compared by eye.
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
    for _d in "$ROOT"/pkgs/*/ "$ROOT"/pkgs/3rdparty/*/; do
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

# True when any recipe needs compiling. This is what
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
# libarchive first rather than failing on an empty sysroot. Alphabetical order
# would put libarchive before zlib.
pkg_order() {
    _order=''; _seen=' '; _path=' '
    for _r in "$@"; do _pkg_visit "$_r"; done
    printf '%s' "${_order# }"
}

_pkg_visit() {
    case "$_seen" in *" $1 "*) return 0 ;; esac
    # A cycle is a recipe reachable from itself, reported by name because the
    # name is what somebody has to fix.
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
    pkg_say "$PKG_ID: building $PKG_NAME $PKG_VERSION-$PKG_RELEASE"
    rm -rf "$PKG_WORK" "$PKG_OUT"
    # src/  unpacked sources        stage/   DESTDIR of the install
    # xw/   compiler wrappers       sysroot/ build dependencies, unpacked
    # dep/  where opkg-unbuild drops them before they are merged into sysroot/
    mkdir -p "$PKG_WORK/src" "$PKG_WORK/stage" "$PKG_WORK/xw/bin" \
             "$PKG_WORK/sysroot" "$PKG_WORK/dep"
    PKG_SYSROOT="$PWD/$PKG_WORK/sysroot"
    PKG_LOG="$PWD/$PKG_WORK"
    # pkg_build's knobs, reset so a recipe only spells what is unusual about
    # its project. See pkg_build.
    PKG_CONFIGURE='./configure'; PKG_CONFIGURE_AUTO=1
    PKG_MAKE_TARGET=''; PKG_INSTALL_TARGET='install'; PKG_MAKE_ARGS=''
    PKG_PY_SETUP_ARGS=''; PKG_CC_SHARED=''
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
# wrappers, put them on PATH, and then prove the wrappers produce the ABI this
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

    # Exported as well as put on PATH, because the two are different
    # handshakes. An autoconf configure finds the cross compiler from --host,
    # by looking for $host-gcc on PATH. OpenSSL takes no --host -- it takes a
    # target name, linux-mips32 -- and reads $CC from the environment, so with
    # PATH alone it silently used the build machine's gcc. Both point at the
    # same wrappers, so a project gets the same compiler either way.
    export CC="$PKG_HOST-gcc"     CXX="$PKG_HOST-g++"
    export AR="$PKG_HOST-ar"      RANLIB="$PKG_HOST-ranlib"
    export STRIP="$PKG_HOST-strip" NM="$PKG_HOST-nm"
    export OBJCOPY="$PKG_HOST-objcopy" OBJDUMP="$PKG_HOST-objdump"
    export LD="$PKG_HOST-ld"

    PKG_STRIP="$_tc/bin/$PKG_HOST-strip"

    # The wrapper is gated before anything is built on it: one that lost
    # -mnan=2008 produces a tree that compiles, links, passes every test on the
    # build host and is refused by the printer's kernel at exec().
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

# ---------------------------------------------------------- pkg_buildpython
#
#     pkg_buildpython
#
# Provide an x86-64 CPython of exactly $PY_VERSION and export $HOSTPY. Nothing
# it produces is ever shipped; it is a compiler for the build machine.
#
# THE VERSIONS MUST MATCH EXACTLY. Cross-compiling CPython needs a build-python
# of the same version -- the Makefile runs it to freeze modules, generate the
# deepfreeze sources and byte-compile the stdlib, and configure hard-errors on
# a mismatch -- so the build image's own python3 cannot stand in. The
# pkg/python-* recipes need it for a second reason: it runs pip and setuptools
# while _PYTHON_SYSCONFIGDATA_NAME makes them answer for mipsel (see
# pkg_pytarget), and an extension compiled against 3.13 headers by a 3.14
# setuptools is an import-time crash on the printer and nowhere else.
#
# ONE CACHE, SHARED BY EVERY PYTHON RECIPE. It lives at work/.py-host rather
# than inside $PKG_WORK, so pkg_end does not delete it. Its stamp is
# $PY_VERSION plus the PEP 517 backend sdists installed into it, because a
# backend bump has to rebuild the thing the backends live in.
#
# --with-ensurepip=install, where the CROSS build has --without-ensurepip and
# must keep it: on a printer pip would need a network and a compiler and has
# neither, while here pip is what builds every wheel. It comes out of the
# pinned tarball, not off bootstrap.pypa.io.
pkg_buildpython() {
    PKG_HOSTPY_ROOT="$PWD/work/.py-host"
    HOSTPY="$PKG_HOSTPY_ROOT/bin/python$PY_MM"
    export HOSTPY

    _hpstamp="$PY_VERSION"
    for _p in setuptools $PYPKG_HOST_LIST; do
        _hpstamp="$_hpstamp $(pypkg_var "$_p" FILE)"
    done
    if [ "$(cat "$PKG_HOSTPY_ROOT/.version" 2>/dev/null || true)" = "$_hpstamp" ]; then
        pkg_skip "$PKG_ID: build-python $PY_VERSION is already at work/.py-host"
        return 0
    fi

    [ -f "${PY_TGZ:-}" ] || pkg_die \
        "$PKG_ID needs the CPython source and '${PY_TGZ:-}' is missing. Run ./bin/fetch-assets.sh."
    command -v gcc >/dev/null || pkg_die \
        "$PKG_ID needs a host gcc to build the build-python. Run through 'make packages'."

    pkg_say "$PKG_ID: building the x86-64 build-python $PY_VERSION (once, then cached)"
    rm -rf "$PKG_HOSTPY_ROOT" work/.py-hostsrc
    mkdir -p work/.py-hostsrc
    tar -xf "$PY_TGZ" -C work/.py-hostsrc \
        || pkg_die "$PKG_ID: could not untar $PY_TGZ"
    _hplog="$PKG_LOG/buildpython.log"
    (
        set -e
        # The cross environment is removed rather than avoided by calling
        # order: pkg_toolchain and pkg_deps may already have exported CC,
        # CFLAGS and a sysroot describing the PRINTER, and a configure that
        # inherits those builds an x86-64 interpreter with mipsel flags and
        # fails somewhere unrecognisable.
        unset CC CXX AR RANLIB STRIP NM OBJCOPY OBJDUMP LD
        unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS LIBS CONFIG_SITE
        unset PKG_CONFIG_LIBDIR PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR
        unset _PYTHON_SYSCONFIGDATA_NAME PYTHONPATH
        cd "work/.py-hostsrc/Python-$PY_VERSION"
        ./configure --prefix="$PKG_HOSTPY_ROOT" --with-ensurepip=install
        make -j"$(nproc 2>/dev/null || echo 4)"
        make install
    ) > "$_hplog" 2>&1 || pkg_die "$PKG_ID: the build-python failed to build -- see $_hplog"

    # zlib is asserted, not assumed: CPython records a missing library as an
    # absent module and carries on. Every wheel is a zip and so is pip, so
    # ensurepip fails with "can't decompress data" inside a make install that
    # reports success, and the symptom arrives three steps later as "No module
    # named pip". zlib1g-dev in docker/Dockerfile.build is the fix.
    "$HOSTPY" -c 'import zlib' 2>/dev/null || pkg_die \
        "the build-python has no zlib module, so it cannot unpack a single wheel. Install zlib1g-dev in docker/Dockerfile.build and delete work/.py-host."
    "$HOSTPY" -m pip --version >> "$_hplog" 2>&1 || pkg_die \
        "the build-python has no pip -- ensurepip failed inside 'make install'; its traceback is in $_hplog"

    # The PEP 517 backends go into the build-python, not an isolated
    # environment per wheel: --no-build-isolation is what keeps
    # _PYTHON_SYSCONFIGDATA_NAME reaching setup.py, and with isolation off the
    # backends have to already be here.
    for _p in setuptools $PYPKG_HOST_LIST; do
        _sd=$(pypkg_tgz "$_p")
        [ -f "$_sd" ] || pkg_die \
            "no sdist for the build backend $_p at '$_sd' -- run ./bin/fetch-assets.sh"
        (
            set -e
            unset CC CXX AR RANLIB STRIP NM OBJCOPY OBJDUMP LD
            unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS LIBS CONFIG_SITE
            unset _PYTHON_SYSCONFIGDATA_NAME PYTHONPATH
            "$HOSTPY" -m pip install --quiet --no-index --no-cache-dir \
                --no-build-isolation --no-deps "$_sd"
        ) >> "$_hplog" 2>&1 || pkg_die \
            "$PKG_ID: could not install the build backend $_p -- see $_hplog"
    done

    rm -rf work/.py-hostsrc
    # Written last, so an interrupted build leaves a stale cache, not a lying
    # one.
    echo "$_hpstamp" > "$PKG_HOSTPY_ROOT/.version"
    pkg_say "$PKG_ID: build-python ready ($("$HOSTPY" -V 2>&1))"
}

# ------------------------------------------------------------ pkg_buildopkg
#
# Build an x86-64 opkg and leave it at work/.opkg-host. This is the tool
# bin/patch.sh assembles the payload with: it installs the feed into a staging
# root, and what lands there is what ships.
#
# WHY A REAL opkg AND NOT pkgs/ipk-install. ipk-install exists because the
# PRINTER has no opkg and no `ar` -- measured, not assumed; see its header.
# Neither constraint is true in this container. What it does not do is resolve
# Depends, enforce Conflicts, read Provides or handle conffiles, and every one
# of those is part of deciding what a payload should contain. Assembling with
# the real client means the payload's own metadata is checked by the code that
# defines what checking it means, and the database it writes is written by the
# program that will later read it on the printer. ipk-install keeps its job,
# which is repairing a machine by hand; it just is not this job.
#
# THE PREFIX IS PART OF THE ABI HERE, exactly as it is for the cross build --
# pkgs/3rdparty/opkg/build.sh spells out why, from measurements taken on both
# sides, and it names an x86-64 opkg as one of them. opkg BAKES ITS STATE
# DIRECTORY IN AT COMPILE TIME: configured anywhere but $MODDIR it looks for
# its status file somewhere else no matter what --offline-root it is handed,
# comes up believing nothing is installed, and cheerfully reinstalls the
# world. So this configures --prefix=$MODDIR and installs with DESTDIR, which
# is why the binary is at $PKG_HOSTOPKG_ROOT$MODDIR/bin/opkg and not at
# $PKG_HOSTOPKG_ROOT/bin/opkg. The path looks redundant and is load-bearing.
#
# ONE CACHE, keyed on the pinned version and its sha256, at work/.opkg-host so
# nothing under $PKG_WORK deletes it -- the same shape as pkg_buildpython
# above, and this function is deliberately its twin so that "build a host tool
# from the pinned source" means one thing in this file.
#
# --disable-curl / --disable-ssl-curl / --disable-gpg follow the cross recipe
# for the same reason it gives: nothing here fetches over a network, every
# .ipk it installs is a local file, and phase 3 of
# docs/notes/85-packaging.md is where that changes.
pkg_buildopkg() {
    PKG_HOSTOPKG_ROOT="$PWD/work/.opkg-host"
    HOSTOPKG="$PKG_HOSTOPKG_ROOT$MODDIR/bin/opkg"
    export HOSTOPKG

    _hostamp="$OPKG_VERSION $OPKG_SHA256 $MODDIR"
    if [ "$(cat "$PKG_HOSTOPKG_ROOT/.version" 2>/dev/null || true)" = "$_hostamp" ]; then
        pkg_skip "build-opkg $OPKG_VERSION is already at work/.opkg-host"
        return 0
    fi

    [ -f "${OPKG_TGZ:-}" ] || pkg_die \
        "the host opkg needs the opkg source and '${OPKG_TGZ:-}' is missing. Run ./bin/fetch-assets.sh."
    command -v gcc >/dev/null || pkg_die \
        "the host opkg needs a host gcc. Run through 'make packages' or 'make build'."
    pkg-config --exists libarchive || pkg_die \
        "the host opkg needs libarchive (opkg's configure.ac says 'Require libarchive'). Install libarchive-dev in docker/Dockerfile.build."

    pkg_say "building the x86-64 build-opkg $OPKG_VERSION (once, then cached)"
    rm -rf "$PKG_HOSTOPKG_ROOT" work/.opkg-hostsrc
    mkdir -p work/.opkg-hostsrc "$PKG_HOSTOPKG_ROOT"
    tar -xf "$OPKG_TGZ" -C work/.opkg-hostsrc \
        || pkg_die "could not untar $OPKG_TGZ"

    # The log lives beside the cache and not under $PKG_WORK: this verb is
    # called from bin/patch.sh, which runs no recipe and so has neither
    # PKG_LOG nor PKG_ID.
    _holog="$PKG_HOSTOPKG_ROOT/build.log"
    (
        set -e
        # THE CROSS ENVIRONMENT IS REMOVED, NOT AVOIDED BY CALLING ORDER --
        # the same argument pkg_buildpython makes, and it applies harder here
        # because a caller may have run a whole cross build first. A configure
        # inheriting CC and a mipsel sysroot builds an opkg this machine
        # cannot execute, and finds out at the first install.
        unset CC CXX AR RANLIB STRIP NM OBJCOPY OBJDUMP LD
        unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS LIBS CONFIG_SITE
        unset PKG_CONFIG_LIBDIR PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR
        cd "work/.opkg-hostsrc/opkg-$OPKG_VERSION"
        # --disable-shared is not a size decision, it is the only way this
        # binary runs. --prefix=$MODDIR bakes /usr/data/anvil into the
        # LIBRARY as well, so a shared build produces a bin/opkg that looks
        # for libopkg.so.1 at a path which exists on the printer and not
        # here. Statically linked, the prefix and the code that reads it are
        # in the one file DESTDIR relocated.
        ./configure --prefix="$MODDIR" \
            --disable-curl --disable-ssl-curl --disable-gpg \
            --disable-shared --enable-static \
            --disable-dependency-tracking
        make -j"$(nproc 2>/dev/null || echo 4)"
        make install DESTDIR="$PKG_HOSTOPKG_ROOT"
    ) > "$_holog" 2>&1 || pkg_die "the host opkg failed to build -- see $_holog"

    [ -x "$HOSTOPKG" ] || pkg_die \
        "the host opkg built but is not at $HOSTOPKG -- check --prefix and DESTDIR; see $_holog"

    # THE BAKED-IN PATH, ASSERTED RATHER THAN ASSUMED. This is the one thing
    # about this build that fails silently: a wrongly-prefixed opkg runs
    # perfectly, writes its database somewhere nobody looks, and hands back a
    # payload the printer's opkg reads as empty. libopkg/Makefile.am compiles
    # in -DVARDIR="@localstatedir@", so the prefix is a literal string inside
    # the binary and the question can be put to the file itself rather than
    # to the configure line that was meant to produce it.
    grep -q -- "$MODDIR/var" "$HOSTOPKG" || pkg_die \
        "the host opkg has no '$MODDIR/var' baked in -- it was configured with the wrong --prefix and would keep its database somewhere the printer never reads. See $_holog."
    "$HOSTOPKG" print-architecture >/dev/null 2>&1 || pkg_die \
        "the host opkg built but cannot run -- see $_holog"

    rm -rf work/.opkg-hostsrc
    # Written LAST, so an interrupted build leaves a cache that is stale
    # rather than one that lies.
    echo "$_hostamp" > "$PKG_HOSTOPKG_ROOT/.version"
    pkg_say "build-opkg ready ($("$HOSTOPKG" --version 2>&1 | head -n1))"
}

# ----------------------------------------------------------------- pkg_deps
#
# Fill the recipe's sysroot from the feed: every recipe named in
# PKG_BUILD_DEPENDS is unpacked out of its own .ipk and merged in, then the
# usual cross-build variables are pointed at the result.
#
# Unpacked by opkg-unbuild, upstream's inverse of opkg-build, so nothing needs
# a working opkg in order to build packages and opkg can be an ordinary recipe
# rather than a bootstrap stage.
#
# BUILDING AGAINST THE PACKAGE, NOT THE BUILD TREE, is the point. Pointing at
# work/pkg/zlib directly would work and would mean nothing ever checks that the
# .ipk contains the headers its dependents need; here a package that forgot to
# ship a header fails the next recipe's configure.
#
# The sysroot mirrors the printer -- dependencies sit under $MODDIR inside it,
# where they will live on the machine -- which is why PKG_CONFIG_SYSROOT_DIR is
# set to the sysroot rather than emptied: the .pc files say
# prefix=/usr/data/anvil, and that variable is what turns their -I and -L into
# paths that exist here.
pkg_deps() {
    [ -n "$PKG_BUILD_DEPENDS" ] || return 0
    for _d in $PKG_BUILD_DEPENDS; do
        # Both halves, when the dependency has two: which of <name> and
        # <name>-dev exists is the dependency's business (anvil-zlib-dev has no
        # runtime half at all), so both are tried and it is an error only if
        # neither is there.
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
# A recipe names where its inputs come from exactly once, with one of the two
# verbs below. Not a style rule: "one recipe builds one source" is checked by
# counting these calls (qa/static/test_ipk.py).
#
# --------------------------------------------------------------- pkg_unpack
#
#     pkg_unpack <archive>
#
# Extract this recipe's one pinned source archive into $PKG_WORK/src.
#
# Zip as well as tar, dispatched on the name, because Mainsail publishes a .zip
# and a second source verb would double the thing being counted. tar reads its
# own compression off the file, so only the container is decided here.
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
# This recipe's sources are the checked-out repository, not a download. Used
# by anvil-core alone, whose contents are payload/ and assets/. It unpacks
# nothing and exists so that "a recipe names its source exactly once" stays a
# countable property with no exemption; the freshness of those inputs is
# PKG_STAMP_EXTRA's job, not this verb's.
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
# This is `make install` for things that have no make -- Mainsail's static
# files, Moonraker's python tree, HelixScreen's prebuilt tarball, anvil-core's
# scripts. Staging them where an autotools install lands means pkg_ship, the
# .la sweep, the archive normalisation and the ELF-only strip need no special
# case for a package that was never compiled.
#
# cp -a: these trees contain symlinks and modes that are part of what ships.
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
# Configure, make, install into the staging tree. The only way a recipe
# compiles anything. Projects differ in the settings of these three steps, not
# in the steps, so the settings are variables:
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
#   PKG_CC_SHARED       the whole link line for a project that has NO BUILD
#                       SYSTEM AT ALL, appended to `$CC -shared -fPIC`. When
#                       it is set there is nothing to configure and nothing to
#                       make, so both steps are skipped and this is the build.
#
# PKG_CC_SHARED EXISTS FOR KLIPPER AND SAYS SO. klippy/chelper has no
# Makefile and never has: on a normal machine klippy compiles c_helper.so at
# first run, from the argument list in klippy/chelper/__init__.py, using
# whatever cc the printer has -- and this printer has none. So the "build
# system" for that .so genuinely is one gcc line, and the recipe's job is to
# state Klipper's own COMPILE_ARGS rather than to invent a link.
#
# WHY IT IS A KNOB HERE AND NOT A gcc LINE IN THE RECIPE. $CC is the wrapper
# pkg_toolchain wrote and gated, which is where -EL -mnan=2008 live. A recipe
# that ran a compiler itself would be free to reach past that -- and the ABI
# flags being spelled in exactly one place is the property
# test_a_recipe_does_not_rebuild_the_shared_parts exists to hold. The recipe
# says WHAT to link; this says HOW, the same split every other knob has.
#
# The prefix is always $MODDIR and the DESTDIR always the recipe's staging tree.
#
# RETURNS NON-ZERO, NEVER DIES. Under the `set -euo pipefail` every recipe runs
# a failure aborts the build anyway; what this buys is the recoverable case.
# OpenSSL's mips target hardcodes -mips2 while this toolchain defaults to
# -mfp64, a combination gcc refuses, and the recovery is to reconfigure for
# portable C -- which `if ! pkg_build` can express and pkg_die could not.
pkg_build() {
    _dir=$1; shift
    _tag=$(basename "$_dir")
    _dest="$PWD/$PKG_WORK/stage"
    (
        set -e
        cd "$PKG_WORK/src/$_dir"

        # No build system: link the sources named by the recipe and stop.
        # -shared -fPIC and $CC are pkg_build's, so a recipe cannot get the
        # ABI or the output kind wrong; everything else is Klipper's own
        # COMPILE_ARGS, spelled in the recipe where a reader can compare it
        # against klippy/chelper/__init__.py.
        if [ -n "${PKG_CC_SHARED:-}" ]; then
            # shellcheck disable=SC2086
            $CC -shared -fPIC $PKG_CC_SHARED > "$PKG_LOG/$_tag-cc.log" 2>&1
            exit 0
        fi

        # The trailing arguments go to whichever step consumes them: to
        # configure when there is one, to make when there is not. bzip2 has no
        # configure, so its CC/AR/RANLIB have to reach make or the library is
        # built with the build machine's compiler.
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
            "$PKG_ID" "$_tag" "$PKG_WORK/$_tag-{configure,make,cc}.log" >&2
        return 1
    }
    pkg_say "$PKG_ID: built $_tag"
}

# ------------------------------------------------------------- pkg_pytarget
#
#     pkg_pytarget
#
# Point the build-python's sysconfig at the TARGET interpreter in the sysroot,
# so that pip and setuptools -- running on x86-64 -- answer every question
# about mipsel. Call it after pkg_toolchain, pkg_deps and pkg_buildpython.
#
# THE CROSS TRICK, with no crossenv in it. anvil-python ships
# lib/python3.13/_sysconfigdata__linux_mipsel-linux-gnu.py, recording the cross
# CC, LDSHARED, EXT_SUFFIX (.cpython-313-mipsel-linux-gnu.so) and INCLUDEPY for
# the target. Pointing _PYTHON_SYSCONFIGDATA_NAME at it from an x86-64 CPython
# of the same version makes sysconfig -- and so setuptools' build_ext -- build
# for mipsel while running on x86-64.
#
# The module is rewritten rather than used as it ships because every path in it
# is /usr/data/anvil/..., which exists on the printer and nowhere here;
# INCLUDEPY in particular has to name a directory that exists or no C extension
# finds Python.h. The substitution is blanket, over every string value rather
# than a list of the variables that matter, because that list is what nobody
# gets right by hand: INCLUDEPY fails loudly, LIBDIR and LIBPL fail quietly.
#
# It goes first on PYTHONPATH, is read only by the build, and never ships.
#
# The pure-python recipes call this too, with nothing to cross-compile:
# sysconfig is what a wheel build asks for its tags and paths whether or not
# there is C in the package, so every recipe runs the same verbs and none has
# to decide which kind it is.
pkg_pytarget() {
    [ -n "${HOSTPY:-}" ] || pkg_die \
        "$PKG_ID: pkg_pytarget needs the build-python -- call pkg_buildpython first"
    [ -n "${PKG_HOST:-}" ] || pkg_die \
        "$PKG_ID: pkg_pytarget needs the cross toolchain -- call pkg_toolchain first"

    PKG_PYROOT="$PKG_SYSROOT$MODDIR"
    PKG_PYINC="$PKG_PYROOT/include/python$PY_MM"
    _sc="_sysconfigdata__linux_mipsel-linux-gnu"
    _scsrc="$PKG_PYROOT/lib/python$PY_MM/$_sc.py"
    [ -f "$_scsrc" ] || pkg_die \
        "$PKG_ID: no $_sc in the sysroot -- is 'python' in PKG_BUILD_DEPENDS?"
    [ -d "$PKG_PYINC" ] || pkg_die \
        "$PKG_ID: no target headers at $PKG_PYINC -- anvil-python-dev is what carries them"

    _xsys="$PWD/$PKG_WORK/xsysconfig"
    rm -rf "$_xsys"; mkdir -p "$_xsys"
    "$HOSTPY" - "$_scsrc" "$_xsys/$_sc.py" "$MODDIR" "$PKG_PYROOT" <<'PYEOF' \
        || pkg_die "$PKG_ID: could not rewrite $_sc for the sysroot"
import sys
src, dst, prefix, sysroot = sys.argv[1:5]
ns = {}
exec(compile(open(src).read(), src, "exec"), ns)
out = {k: (v.replace(prefix, sysroot) if isinstance(v, str) else v)
       for k, v in ns["build_time_vars"].items()}
with open(dst, "w") as fh:
    fh.write("# Generated by pkgs/lib.sh: %s with the build-time prefix rewritten\n"
             "# to this recipe's sysroot. Build-time only; never ships.\n"
             "build_time_vars = %r\n" % (src, out))
PYEOF

    export _PYTHON_SYSCONFIGDATA_NAME="$_sc"
    # Only the rewritten module, deliberately not the target's stdlib as well:
    # the one thing that has to be importable is this, and adding the target's
    # stdlib puts the host interpreter importing the target's os.py one
    # path-ordering mistake away.
    export PYTHONPATH="$_xsys"
    export PYTHONDONTWRITEBYTECODE=1
    export PIP_DISABLE_PIP_VERSION_CHECK=1
    # setuptools does not forward CFLAGS to its link lines, which is why the
    # -EL -mnan=2008 that decide this printer's ABI live in the gcc wrapper
    # pkg_toolchain wrote. What is passed here only helps a compile find
    # headers.
    export LDSHARED="$PKG_HOST-gcc -shared -L$PKG_PYROOT/lib"
    export CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64 -I$PKG_PYROOT/include -I$PKG_PYINC"
    export CXXFLAGS="$CFLAGS"

    # Where every wheel is unpacked: the recipe's own staging tree, at the
    # path site-packages has on the printer. pkg_ship reads from here.
    PKG_PYSP="$PWD/$PKG_WORK/stage$MODDIR/lib/python$PY_MM/site-packages"
    mkdir -p "$PKG_PYSP"

    # Gated before anything is built on it: if _PYTHON_SYSCONFIGDATA_NAME has
    # not taken, sysconfig answers every later question for x86-64 and the
    # result is a tree of host objects that builds perfectly and imports
    # nowhere.
    "$HOSTPY" - "$PKG_PYINC" ".cpython-$(printf '%s' "$PY_MM" | tr -d .)-mipsel-linux-gnu.so" <<'PYEOF' \
        || pkg_die "$PKG_ID: the sysconfig cross trick did not take"
import os, sys, sysconfig
inc_want, suffix_want = sys.argv[1:3]
suffix = sysconfig.get_config_var("EXT_SUFFIX")
inc = sysconfig.get_config_var("INCLUDEPY")
if suffix != suffix_want:
    raise SystemExit("   !! sysconfig is answering for the HOST (EXT_SUFFIX=%s,"
                     " wanted %s) -- _PYTHON_SYSCONFIGDATA_NAME did not take"
                     % (suffix, suffix_want))
if inc != inc_want:
    raise SystemExit("   !! INCLUDEPY is %s, expected %s" % (inc, inc_want))
if not os.path.isdir(inc):
    raise SystemExit("   !! INCLUDEPY %s does not exist" % inc)
PYEOF
    pkg_say "$PKG_ID: sysconfig answers for mipsel, headers at $PKG_PYINC"
}

# ---------------------------------------------------------------- pkg_pysrc
#
#     pkg_pysrc <list-entry>
#
# Where this package's sdist unpacked to: every PyPI sdist unpacks to a
# directory named after the file with .tar.gz removed, under $PKG_WORK/src.
pkg_pysrc() {
    _f=$(pypkg_var "$1" FILE)
    printf '%s/src/%s' "$PKG_WORK" "${_f%.tar.gz}"
}

# -------------------------------------------------------------- pkg_pywheel
#
#     pkg_pywheel <list-entry> [VAR=VAL ...]
#
# Build one wheel for the target out of the source pkg_unpack just extracted,
# and unpack it into the staging site-packages. Trailing VAR=VAL pairs are
# environment for that build alone (lmdb needs one).
#
# It takes the package name and not a path, and builds from the unpacked
# directory rather than the sdist, so that every recipe reads the same way --
# greenlet has to patch its sources before they compile and pillow has to be
# driven through setup.py, and pip builds a directory exactly as it builds an
# sdist.
#
# NOTHING HERE TALKS TO A NETWORK. pip runs --no-index against a tree that came
# out of an archive bin/fetch-assets.sh already checked the sha256 of.
# --no-binary :all: is kept as well: the day someone adds an index URL for one
# awkward package, it is what stops x86-64 .so files sailing into the tree.
#
#   PKG_PY_SETUP_ARGS   drive setup.py build_ext with these options and then
#                       bdist_wheel, instead of calling pip. PEP 517 offers no
#                       way to pass build_ext options, and pillow's --disable-*
#                       are build_ext options.
#
# Unzipped rather than pip-installed, because `pip install` installs FOR the
# interpreter running it, which is x86-64. A wheel's layout is already the
# layout of site-packages.
#
# .dist-info goes: nothing on the printer resolves a dependency, asks for a
# version or runs an entry point. The .data directories and their scripts go
# for a stronger reason -- their console-script shebangs name the
# build-python's path under work/.py-host.
pkg_pywheel() {
    _pw=$1; shift
    _wdir=$(pkg_pysrc "$_pw")
    [ -d "$_wdir" ] || pkg_die \
        "$PKG_ID: $(pypkg_var "$_pw" FILE) did not unpack to $(basename "$_wdir")"
    [ -n "${PKG_PYSP:-}" ] || pkg_die \
        "$PKG_ID: pkg_pywheel needs the target environment -- call pkg_pytarget first"
    _wheels="$PWD/$PKG_WORK/wheels"
    rm -rf "$_wheels"; mkdir -p "$_wheels"
    _wlog="$PKG_LOG/wheel-$_pw.log"

    if [ -n "${PKG_PY_SETUP_ARGS:-}" ]; then
        (
            set -e
            cd "$_wdir"
            # Deliberately unquoted: PKG_PY_SETUP_ARGS is a list of options.
            # shellcheck disable=SC2086
            env "$@" "$HOSTPY" setup.py build_ext $PKG_PY_SETUP_ARGS bdist_wheel
        ) > "$_wlog" 2>&1 || {
            printf '   !! %s: %s failed to build -- see %s\n' "$PKG_ID" "$_pw" "$_wlog" >&2
            tail -25 "$_wlog" | sed 's/^/      /' >&2
            return 1; }
        cp -a "$_wdir"/dist/*.whl "$_wheels/" \
            || pkg_die "$PKG_ID: $_pw's setup.py produced no wheel -- see $_wlog"
    else
        env "$@" "$HOSTPY" -m pip wheel --no-deps --no-build-isolation \
            --no-index --no-binary :all: --no-cache-dir -w "$_wheels" "$_wdir" \
            > "$_wlog" 2>&1 || {
            printf '   !! %s: %s failed to build -- see %s\n' "$PKG_ID" "$_pw" "$_wlog" >&2
            tail -25 "$_wlog" | sed 's/^/      /' >&2
            return 1; }
    fi

    _nw=0
    for _w in "$_wheels"/*.whl; do
        [ -f "$_w" ] || continue
        "$HOSTPY" -m zipfile -e "$_w" "$PKG_PYSP" \
            || pkg_die "$PKG_ID: could not unpack $(basename "$_w") into site-packages"
        pkg_say "$PKG_ID: $(basename "$_w")"
        _nw=$((_nw + 1))
    done
    [ "$_nw" -gt 0 ] || pkg_die "$PKG_ID: no wheel came out of $_pw -- see $_wlog"

    find "$PKG_PYSP" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
    find "$PKG_PYSP" -maxdepth 1 -name '*.dist-info' -prune -exec rm -rf {} + 2>/dev/null || true
    rm -rf "${PKG_PYSP:?}"/bin "${PKG_PYSP:?}"/*.data
}

# --------------------------------------------------------------- pkg_ship
#
#     pkg_ship <relative-glob> [...]
#
# Copy what the package contains out of the staged install and into $PKG_OUT,
# which is the tree bin/build-packages.sh packages and bin/patch.sh stages.
# Globs are relative to the prefix inside the DESTDIR.
#
# cp -a and never plain cp: a shared library is three names, two of them
# symlinks, and the first is the one libnacl's dlopen fallback constructs. A
# copy that dereferenced them would ship three identical objects and still work.
#
# What a package contains depends on what it is for -- a library that ships to
# the printer ships its .so alone, one that exists to be built against ships
# headers, .a and .pc -- so neither is the default and each recipe says which
# it is by what it passes here.
#
# PKG_STRIP_ARGS is --strip-unneeded by default, keeping the dynamic symbols
# anything is going to dlsym; a recipe shipping executables can set it empty
# for a plain strip-all. Static archives and text files are never stripped:
# strip on a .a removes symbols the linker still needs.
pkg_ship() {
    for _g in "$@"; do
        _dstdir="$PKG_OUT/$(dirname "$_g")"
        mkdir -p "$_dstdir"
        _n=0
        # Deliberately unquoted: $_g is a glob and this is where it expands.
        # Not `set --`, which would destroy this function's own positional
        # parameters as a side effect.
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

    # NEITHER IS PYTHON BYTECODE, and this one was shipping. anvil-core stages
    # a directory of .py helpers wholesale, and any test that imports one of
    # them leaves a __pycache__ beside it -- gitignored, so invisible in a
    # diff, and copied by cp -a like anything else. The result was a package
    # whose contents depended on whether pytest had been run on the machine
    # that built it: two builds of one commit, different sha256, and the
    # cause nowhere in the tree.
    #
    # What it shipped is worthless as well as unstable. The .pyc were compiled
    # by the BUILD IMAGE's python (3.11), and the printer runs the 3.13 this
    # repo cross-builds, which will not read them.
    #
    # Swept here rather than in the recipe because the trap is not
    # anvil-core's: it is set for any recipe that stages a directory of .py
    # files. Two recipes had already hit it and each had written its own
    # sweep -- pkgs/klipper and pkgs/moonraker -- and the third, which had
    # not, was the one shipping. Both hand-written copies are deleted with
    # this. Nothing in this feed ships bytecode deliberately, checked across
    # all 41 packages, so there is nothing for this to take away.
    find "$PKG_OUT" -name '__pycache__' -type d -prune -exec rm -rf {} + \
        2>/dev/null || true
    find "$PKG_OUT" -name '*.pyc' -delete

    # STATIC ARCHIVES ARE NOT REPRODUCIBLE UNTIL THEY ARE MADE SO. An ar
    # archive stores a per-member mtime and the uid/gid of whoever ran the
    # compiler, and the symbol index carries a timestamp of its own, so a
    # package differs between two builds of one tree and between two
    # developers' accounts on one commit. SOURCE_DATE_EPOCH and opkg-build's
    # `-o 0 -g 0` clamp the tarballs one layer up and reach nothing inside a .a.
    #
    # The two timestamps take two tools:
    #
    #   objcopy -D   zeroes uid, gid and mtime in the MEMBER headers.
    #   ranlib  -D   rewrites the symbol INDEX with a zeroed header.
    #
    # The cross binutils is 2.27 and its ranlib does not honour -D for the
    # index -- measured, it wrote the CURRENT timestamp instead -- so the index
    # is rewritten with the build machine's ranlib (2.40 in
    # docker/Dockerfile.build). ar is a container format and ranlib reads
    # members through BFD, so a modern host binutils indexes mipsel objects
    # correctly; opkg links against both archives, which is what would fail if
    # it did not.
    #
    # Both passes need the cross toolchain, and a recipe that compiles nothing
    # never called pkg_toolchain -- it has no archive to normalise and no ELF
    # to strip. Skipping is safe because mips_abi_gate in
    # bin/build-packages.sh reads every ELF at the package boundary, so a
    # recipe that forgot pkg_toolchain and did produce objects is caught there
    # rather than here by an unbound variable.
    if [ -n "${PKG_HOST:-}" ]; then
        find "$PKG_OUT" -name '*.a' -print | while IFS= read -r _a; do
            "$PKG_HOST-objcopy" --enable-deterministic-archives "$_a" \
                || pkg_die "$PKG_ID: could not normalise the member headers of $_a"
            ranlib -D "$_a" \
                || pkg_die "$PKG_ID: could not write a deterministic index for $_a"
        done

        find "$PKG_OUT" -type f -print | while IFS= read -r _f; do
            case "$_f" in *.a|*.h|*.pc|*.la) continue ;; esac
            # readelf is the ELF test: it exits non-zero on anything else.
            "$PKG_HOST-readelf" -h "$_f" >/dev/null 2>&1 || continue
            # The cross strip; the host's would refuse a MIPS object.
            # shellcheck disable=SC2086
            "$PKG_STRIP" ${PKG_STRIP_ARGS---strip-unneeded} "$_f" 2>/dev/null || true
        done
    fi
}
