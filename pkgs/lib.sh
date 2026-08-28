# The part of a cross-build that is the same for every package.
#
# Sourced by every recipe's build.sh, after bin/common.sh.
#
# ONE RECIPE BUILDS ONE SOURCE. That is the rule this file exists to make
# cheap. A recipe unpacks one source, builds it, and ships it; anything it
# needs to build against arrives as a package that some other recipe produced,
# unpacked out of the feed by pkg_deps. The alternative -- a recipe that builds
# its own dependencies inline, which is what pkgs/3rdparty/opkg used to do with zlib and
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
#     . ./bin/common.sh
#     . pkgs/lib.sh
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
# pkg_stamp folds it in; see pkgs/anvil-core/pkg.conf.
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
# libarchive first rather than failing on an empty sysroot.
#
# Alphabetical order, which is what iterating the recipe directories gives
# you, is wrong the
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

# ---------------------------------------------------------- pkg_buildpython
#
#     pkg_buildpython
#
# Provide an x86-64 CPython of exactly $PY_VERSION and export $HOSTPY.
#
# IT SITS BESIDE pkg_toolchain BECAUSE IT IS THE SAME KIND OF THING: a
# compiler for the build machine, not a file for the printer. pkg_toolchain
# unpacks one and this one compiles it, which is an implementation detail of
# the same sentence -- nothing either of them produces is ever shipped, and no
# recipe should be spelling out how to get one.
#
# WHY THE VERSIONS MUST MATCH EXACTLY. Cross-compiling CPython needs a
# build-python OF THE SAME VERSION: the Makefile runs it to freeze modules,
# generate the deepfreeze sources and byte-compile the stdlib, and configure
# hard-errors when the version does not match. The build image's own python3
# cannot stand in. And the eighteen pkgs/3rdparty/python-* recipes need it for a second
# reason -- it is the interpreter that runs pip and setuptools while
# _PYTHON_SYSCONFIGDATA_NAME makes them answer for mipsel (see pkg_pytarget),
# and an extension module compiled against 3.13 headers by a 3.14 setuptools
# is an import-time crash on the printer and nowhere else.
#
# ONE CACHE, SHARED BY NINETEEN RECIPES. It lives at work/.py-host rather than
# inside $PKG_WORK, so pkg_end does not delete it and the second recipe to ask
# gets it for the price of reading a stamp. That stamp is $PY_VERSION plus the
# PEP 517 backend sdists installed into it, because a backend bump has to
# rebuild the thing the backends live in.
#
# --with-ensurepip=install, where the CROSS build has --without-ensurepip and
# must keep it. The two are opposite answers to opposite questions: on a
# printer pip would need a network and a compiler and has neither, while HERE
# pip is what builds every wheel -- and it comes out of the pinned tarball
# rather than off bootstrap.pypa.io, which is the difference between a build
# machine that downloads and runs an unpinned get-pip.py and one that does not
# talk to anybody.
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
        # THE CROSS ENVIRONMENT IS REMOVED, NOT AVOIDED BY CALLING ORDER. A
        # recipe is free to call pkg_toolchain and pkg_deps before this, and
        # both export CC, CFLAGS and a sysroot that describe the PRINTER. A
        # configure run inheriting those builds an x86-64 interpreter with
        # mipsel flags and fails somewhere unrecognisable. Unsetting them here
        # means this verb means the same thing wherever it appears in a recipe.
        unset CC CXX AR RANLIB STRIP NM OBJCOPY OBJDUMP LD
        unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS LIBS CONFIG_SITE
        unset PKG_CONFIG_LIBDIR PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR
        unset _PYTHON_SYSCONFIGDATA_NAME PYTHONPATH
        cd "work/.py-hostsrc/Python-$PY_VERSION"
        ./configure --prefix="$PKG_HOSTPY_ROOT" --with-ensurepip=install
        make -j"$(nproc 2>/dev/null || echo 4)"
        make install
    ) > "$_hplog" 2>&1 || pkg_die "$PKG_ID: the build-python failed to build -- see $_hplog"

    # zlib, ASSERTED RATHER THAN ASSUMED, because CPython's answer to a missing
    # library is to record the module as absent and carry on. Every wheel is a
    # zip and so is pip: ensurepip installs it out of a bundled .whl, and
    # without zlib that fails with "can't decompress data" INSIDE a make
    # install that reports success. The symptom then arrives three steps later
    # as "No module named pip", nowhere near the cause. zlib1g-dev in
    # docker/Dockerfile.build is the fix, and this is the sentence that says so.
    "$HOSTPY" -c 'import zlib' 2>/dev/null || pkg_die \
        "the build-python has no zlib module, so it cannot unpack a single wheel. Install zlib1g-dev in docker/Dockerfile.build and delete work/.py-host."
    "$HOSTPY" -m pip --version >> "$_hplog" 2>&1 || pkg_die \
        "the build-python has no pip -- ensurepip failed inside 'make install'; its traceback is in $_hplog"

    # The PEP 517 backends, into the build-python rather than into an isolated
    # environment per wheel: --no-build-isolation is what keeps
    # _PYTHON_SYSCONFIGDATA_NAME reaching setup.py, and with isolation off the
    # backends have to already be here. All three bootstrap themselves through
    # backend-path, so --no-index proves nothing outside vendor/ is needed.
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
    # Written LAST, so an interrupted build leaves a cache that is stale rather
    # than one that lies.
    echo "$_hpstamp" > "$PKG_HOSTPY_ROOT/.version"
    pkg_say "$PKG_ID: build-python ready ($("$HOSTPY" -V 2>&1))"
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
# ONE RECIPE USES THIS AND IT IS anvil-core, whose contents are its own
# payload/ -- files that are edited in this repo rather than fetched from
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
# pkgs/3rdparty/zlib, sanctioned by a carve-out in the test that forbids every other
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
# THE CROSS TRICK, AND THERE IS NO crossenv IN IT. anvil-python ships
# lib/python3.13/_sysconfigdata__linux_mipsel-linux-gnu.py, which records the
# cross CC, LDSHARED, EXT_SUFFIX (.cpython-313-mipsel-linux-gnu.so) and
# INCLUDEPY for the TARGET. Point _PYTHON_SYSCONFIGDATA_NAME at it from an
# x86-64 CPython of the same version and sysconfig -- and therefore
# setuptools' build_ext -- builds for mipsel while running on x86-64.
#
# WHY THE MODULE IS REWRITTEN RATHER THAN USED AS IT SHIPS. Every path in it
# is /usr/data/anvil/..., which is where those files live ON THE PRINTER and
# nowhere on this machine; INCLUDEPY in particular has to name a directory
# that exists or every C extension fails to find Python.h. The spike solved
# that with a container and a bind mount. Here the whole module is rewritten
# with $MODDIR replaced by the sysroot that pkg_deps just filled -- a blanket
# substitution over every string value rather than a list of the variables
# that matter, because the list of variables that matter is exactly the thing
# nobody gets right by hand: INCLUDEPY fails loudly, LIBDIR and LIBPL fail
# quietly, and a future setuptools is free to ask for another.
#
# It goes first on PYTHONPATH, is read only by the build, and never ships.
#
# THE PURE-PYTHON RECIPES CALL THIS TOO, and there is nothing for it to
# cross-compile in them. That is deliberate: sysconfig is what a wheel build
# asks for its tags and its paths whether or not there is any C in the package,
# so running the same five verbs in all eighteen recipes means none of them has
# to decide which kind it is -- and a package that grows a C accelerator in
# some future release does not need its recipe rewritten to notice.
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
    # ONLY the rewritten module -- deliberately NOT the target's stdlib as
    # well, which is what the spike put here. They are the same CPython, so it
    # did no harm, but it also means the host interpreter importing the
    # TARGET's os.py by accident is one path-ordering mistake away, and the
    # only thing that has to be importable is this.
    export PYTHONPATH="$_xsys"
    export PYTHONDONTWRITEBYTECODE=1
    export PIP_DISABLE_PIP_VERSION_CHECK=1
    # setuptools does NOT forward CFLAGS to its link lines, which is why the
    # -EL -mnan=2008 that decide this printer's ABI are baked into the gcc
    # wrapper pkg_toolchain wrote and not passed here. What is passed here is
    # only what a compile needs to find headers.
    export LDSHARED="$PKG_HOST-gcc -shared -L$PKG_PYROOT/lib"
    export CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64 -I$PKG_PYROOT/include -I$PKG_PYINC"
    export CXXFLAGS="$CFLAGS"

    # Where every wheel is unpacked: the recipe's own staging tree, at the
    # path site-packages has on the printer. pkg_ship reads from here.
    PKG_PYSP="$PWD/$PKG_WORK/stage$MODDIR/lib/python$PY_MM/site-packages"
    mkdir -p "$PKG_PYSP"

    # GATED BEFORE ANYTHING IS BUILT ON IT. If _PYTHON_SYSCONFIGDATA_NAME has
    # not taken, every question sysconfig is asked below is answered for
    # x86-64 -- and the answer is a tree of host objects that builds
    # perfectly, passes every test here and imports nowhere.
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
# Where this package's sdist unpacked to. Every sdist on PyPI unpacks to a
# directory named after the file with .tar.gz removed, and pkg_unpack put it
# under $PKG_WORK/src -- so this is that path, spelled once instead of in
# eighteen recipes.
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
# IT TAKES THE PACKAGE NAME AND NOT A PATH so that every recipe reads the same
# way and none of them spells $PKG_WORK. It builds from the UNPACKED
# DIRECTORY rather than from the sdist for the same reason: greenlet has to
# patch its sources before they compile and pillow has to be driven through
# setup.py, and if those two took a directory while the other sixteen took a
# tarball then two thirds of the recipes would differ in shape for no reason a
# reader could see. pip builds a directory exactly as it builds an sdist.
#
# NOTHING HERE TALKS TO A NETWORK. pip runs --no-index against a tree that came
# out of an archive bin/fetch-assets.sh already checked the sha256 of, which is
# the strong form of the rule that --no-binary :all: is the weak form of: pip
# cannot download a wheel it cannot reach. Both are kept, because the day
# someone adds an index URL for one awkward package the second one is what
# stops three x86-64 .so files from sailing into the tree -- which is not
# hypothetical, it is what happened on the spike's first run.
#
#   PKG_PY_SETUP_ARGS   drive setup.py build_ext with these options and then
#                       bdist_wheel, instead of calling pip. PEP 517 offers no
#                       way to pass build_ext options, and pillow's --disable-*
#                       are build_ext options.
#
# UNZIPPED RATHER THAN pip-installed, because `pip install` insists on
# installing FOR the interpreter running it -- and that one is x86-64. A wheel
# is a zip whose layout is already the layout of site-packages, so unzipping it
# is the whole of what an install does here.
#
# .dist-info GOES: nothing on the printer resolves a dependency, asks for a
# version or runs an entry point, and it is metadata describing a build machine
# to nobody. The .data directories and the scripts in them go for a stronger
# reason -- their console-script shebangs name the BUILD-PYTHON's path, so
# shipping them would put files on the printer that reference work/.py-host.
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
    # archive stores, per member, an mtime and the uid/gid of whoever ran the
    # compiler, and the symbol index carries a timestamp of its own. Measured:
    # two cold builds of pkgs/3rdparty/zlib an hour apart produced .ipk files with
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
