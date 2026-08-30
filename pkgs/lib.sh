# The part of a cross-build that is the same for every package. Sourced by
# every recipe's build.sh after bin/common.sh, and by bin/payload.sh for pkg_out
# alone. Recipes run as their own process, so no cross CC leaks onward.
#
# ONE RECIPE BUILDS ONE SOURCE: exactly one source verb per recipe, counted by
# qa/static/test_ipk.py. One build may still produce two archives, <name> and
# <name>-dev (PKG_DEV_FILES).
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
# Version, dependencies and metadata live in the recipe's pkg.conf. Everything
# cross-compiles with the one Ingenic glibc 2.29 / gcc 7.2 toolchain.

pkg_say()  { printf '>> %s\n' "$*"; }
pkg_skip() { printf '   (skip) %s\n' "$*"; }
pkg_die()  { printf '   !! %s\n' "$*" >&2; exit 1; }

# pkg_conf <recipe-id> -- read pkg/<id>/pkg.conf into the PKG_* metadata.
# Sets no build state, so pkg_stamp can read another recipe's in a subshell.
#   PKG_BUILD_DEPENDS  recipe ids; build order and pkg_deps only. PKG_DEPENDS
#                      is what opkg reads. Keeping them apart stops a runtime
#                      dependency on a merely-linked library.
#   PKG_STAMP_EXTRA    content hash for inputs no version number describes.
#   PKG_DEV_FILES      files that move into <name>-dev, section libdevel.
#   PKG_WHEN           whether the recipe exists at all; empty means always.
#                      A false condition is absence, not failure.

# PKG_STAMP_EXTRA="$(pkg_payload_hash)" -- sixteen hex digits over payload/
# and control/, for the half of a package that comes out of this checkout
# rather than a tarball; without it the stamp reports "already current" and
# hands back the previous build. control/ counts, because an edited postinst
# changes what the .ipk does; seed/ ships in nothing. $PKG_DIR is already set.
#
# TWO find CALLS AND AN `|| true`: `find a b` with b missing exits non-zero,
# which under the recipes' `set -euo pipefail` kills the build silently.
pkg_payload_hash() {
    {   find "$PKG_DIR/payload" -type f -print0 2>/dev/null || true
        find "$PKG_DIR/control" -type f -print0 2>/dev/null || true
    }   | LC_ALL=C sort -z | xargs -0 sha256sum 2>/dev/null \
        | sha256sum | cut -c1-16
}

# pkg_dir <recipe-id> -> the directory holding its pkg.conf. Recipes live at
# two depths and this is the only function that knows it:
#     pkgs/<name>/            carries files of this repo -- a payload/, prog/
#                             or seed/. Four of them.
#     pkgs/3rdparty/<name>/   builds a pinned tarball, stages nothing from the
#                             checkout. Thirty-four.
# Names are unique ACROSS both levels, since pkg_out, pkg_stamp and the .ipk
# filename are keyed by the bare name; qa/static/test_recipe_layout.py holds
# that and the split, which is mechanical rather than editorial.
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
    # PKG_DIR is set before the file is sourced, so pkg.conf and build.sh can
    # name their own directory without spelling out where recipes live.
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

# The cache key for a recipe: its version, the toolchain that determines its
# ABI, and recursively the stamp of all it builds against, so a zlib bump
# rebuilds libarchive and opkg. From pkg.conf alone, so bin/fetch-assets.sh
# can ask whether a build needs a compiler before one exists.
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
        # PKG_WHEN in a subshell: arbitrary shell out of a recipe's metadata,
        # and this is called by the fetcher, the packager and the tests.
        ( pkg_conf "$_r"; [ -z "$PKG_WHEN" ] || eval "$PKG_WHEN" ) || continue
        printf '%s\n' "$_r"
    done
}

# True when any recipe needs compiling -- what bin/fetch-assets.sh asks before
# pulling the ~203MB toolchain.
pkg_needs() {
    for _r in $(pkg_recipes); do
        if pkg_stale "$_r"; then return 0; fi
    done
    return 1
}

# pkg_order <recipe-id>... -- the given recipes and all they build against,
# dependency first. Depth-first, so one recipe gets its whole closure:
# `PKG=opkg make packages` builds zlib and libarchive first, where
# alphabetical order would invert those two.
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

# pkg_begin <recipe-id> -- read the recipe's metadata, check the cache, lay
# out the scratch tree. Non-zero when the output is already current, so every
# recipe starts `pkg_begin <id> || exit 0`.
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

# Unpack the toolchain, write the compiler wrappers, put them on PATH, and
# prove they produce the ABI this printer's kernel will exec. -mnan=2008 and
# -EL are baked into the compiler DRIVER, not CFLAGS: autotools link lines do
# not all forward CFLAGS, and one object linked without them poisons the whole
# binary's ABI flags.
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

    # Exported as well as on PATH: an autoconf configure finds the cross
    # compiler as $host-gcc on PATH, while OpenSSL takes a target name and
    # reads $CC from the environment.
    export CC="$PKG_HOST-gcc"     CXX="$PKG_HOST-g++"
    export AR="$PKG_HOST-ar"      RANLIB="$PKG_HOST-ranlib"
    export STRIP="$PKG_HOST-strip" NM="$PKG_HOST-nm"
    export OBJCOPY="$PKG_HOST-objcopy" OBJDUMP="$PKG_HOST-objdump"
    export LD="$PKG_HOST-ld"

    PKG_STRIP="$_tc/bin/$PKG_HOST-strip"

    # Gated before anything is built on it: a wrapper that lost -mnan=2008
    # builds a tree that passes every test here and is refused at exec().
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

# An x86-64 CPython of exactly $PY_VERSION, exported as $HOSTPY. Nothing it
# produces ships; it is a compiler for the build machine.
#
# THE VERSIONS MUST MATCH EXACTLY. Cross-compiling CPython needs a
# build-python of the same version and configure hard-errors on a mismatch, so
# the build image's python3 cannot stand in. The pkg/python-* recipes need it
# for a second reason: it runs pip and setuptools under
# _PYTHON_SYSCONFIGDATA_NAME (see pkg_pytarget), and an extension compiled
# against 3.13 headers by a 3.14 setuptools crashes at import on the printer.
#
# One cache for every python recipe, at work/.py-host so pkg_end does not
# delete it, stamped on $PY_VERSION plus the PEP 517 backend sdists.
# --with-ensurepip=install, where the cross build has --without-ensurepip:
# here pip is what builds every wheel.
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
        # order: a configure inheriting the printer's CC and sysroot builds an
        # x86-64 interpreter with mipsel flags.
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
    # absent module and carries on, so ensurepip fails inside a make install
    # that reports success and surfaces later as "No module named pip".
    "$HOSTPY" -c 'import zlib' 2>/dev/null || pkg_die \
        "the build-python has no zlib module, so it cannot unpack a single wheel. Install zlib1g-dev in docker/Dockerfile.build and delete work/.py-host."
    "$HOSTPY" -m pip --version >> "$_hplog" 2>&1 || pkg_die \
        "the build-python has no pip -- ensurepip failed inside 'make install'; its traceback is in $_hplog"

    # The backends go into the build-python, not a per-wheel isolated
    # environment: --no-build-isolation is what keeps
    # _PYTHON_SYSCONFIGDATA_NAME reaching setup.py.
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

# Fill the recipe's sysroot from the feed: everything in PKG_BUILD_DEPENDS is
# unpacked out of its own .ipk by opkg-unbuild and merged in, then the
# cross-build variables point at the result. Building against the package
# rather than the build tree is the point -- one that forgot to ship a header
# fails the next recipe's configure. The sysroot mirrors the printer, deps
# under $MODDIR inside it, so PKG_CONFIG_SYSROOT_DIR is set to the sysroot
# rather than emptied: the .pc files say prefix=/usr/data/anvil.
pkg_deps() {
    [ -n "$PKG_BUILD_DEPENDS" ] || return 0
    for _d in $PKG_BUILD_DEPENDS; do
        # Both halves, when the dependency has two: which of <name> and
        # <name>-dev exists is the dependency's business, so only neither is
        # an error.
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

# SOURCE VERBS. A recipe names where its inputs come from exactly once, with
# one of the verbs below; qa/static/test_ipk.py counts these calls.
#
# pkg_unpack <archive> -- extract this recipe's one pinned source archive into
# $PKG_WORK/src. Zip as well as tar, dispatched on the name, because Mainsail
# publishes a .zip.
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

# pkg_intree -- this recipe's sources are the checked-out repository, not a
# download; anvil-core alone. Unpacks nothing, and exists so the source-verb
# count needs no exemption. Freshness of those inputs is PKG_STAMP_EXTRA's job.
pkg_intree() {
    PKG_SRC="$ROOT"
    pkg_say "$PKG_ID: source is this checkout, at $ROOT"
}

# pkg_prebuilt <path> -- this recipe's source is a finished binary from
# outside the build, a path in config.env. pkgs/busybox alone, and it should
# stay that way: a recipe reading a typed path cannot promise a rebuild from a
# sha256. A source verb rather than a helper so the same count covers it.
pkg_prebuilt() {
    [ -f "${1:-}" ] || pkg_die \
        "$PKG_ID: no binary at '${1:-}' -- check the path in config.env"
    PKG_SRC=$1
    pkg_say "$PKG_ID: source is a prebuilt binary, at $1"
}

# pkg_stage <src> <dest-relative-to-prefix> -- put a file or tree where
# pkg_ship expects it, $PKG_WORK/stage$MODDIR/<dest>. `make install` for things
# that have no make (Mainsail's static files, Moonraker's python tree,
# anvil-core's scripts), landing them where an autotools install would so
# pkg_ship needs no special case. cp -a, because these trees contain symlinks
# and modes that are part of what ships.
pkg_stage() {
    [ -e "${1:-}" ] || pkg_die "$PKG_ID: nothing to stage at '${1:-}'"
    [ -n "${2:-}" ] || pkg_die "$PKG_ID: pkg_stage needs a destination"
    _dst="$PKG_WORK/stage$MODDIR/$2"
    mkdir -p "$(dirname "$_dst")"
    cp -a "$1" "$_dst" || pkg_die "$PKG_ID: could not stage $1 -> $2"
}

# pkg_build <srcdir-under-src> [configure args...] -- configure, make, install
# into the staging tree; the only way a recipe compiles anything. Projects
# differ in the settings of those three steps, not in the steps:
#   PKG_CONFIGURE       the configure program.        default ./configure
#                       'none' skips the step entirely (bzip2).
#   PKG_CONFIGURE_AUTO  1 = prepend --host and --prefix, which an autoconf
#                       configure wants and zlib and OpenSSL refuse.
#   PKG_MAKE_TARGET     what to build.                default: everything
#   PKG_INSTALL_TARGET  how to install it.            default install
#                       'none' = the recipe places the files itself.
#   PKG_MAKE_ARGS       extra variables for make (LDLIBS=-lpthread for s6).
#   PKG_CC_SHARED       the whole link line for a project with no build system
#                       at all, appended to `$CC -shared -fPIC`; when set,
#                       configure and make are skipped.
#
# PKG_CC_SHARED exists for Klipper: klippy/chelper has no Makefile and
# normally compiles c_helper.so at first run with a cc this printer lacks. A
# knob rather than a gcc line in the recipe because $CC is the gated wrapper
# where -EL -mnan=2008 live.
#
# RETURNS NON-ZERO, NEVER DIES, for the recoverable case: OpenSSL's mips
# target hardcodes -mips2 against this toolchain's -mfp64, which gcc refuses,
# and `if ! pkg_build` can express the retry that pkg_die could not.
pkg_build() {
    _dir=$1; shift
    _tag=$(basename "$_dir")
    _dest="$PWD/$PKG_WORK/stage"
    (
        set -e
        cd "$PKG_WORK/src/$_dir"

        # No build system: link the sources named by the recipe and stop.
        # -shared -fPIC and $CC are pkg_build's; the rest is Klipper's own
        # COMPILE_ARGS, spelled in the recipe against chelper/__init__.py.
        if [ -n "${PKG_CC_SHARED:-}" ]; then
            # shellcheck disable=SC2086
            $CC -shared -fPIC $PKG_CC_SHARED > "$PKG_LOG/$_tag-cc.log" 2>&1
            exit 0
        fi

        # Trailing arguments go to whichever step consumes them: configure
        # when there is one, make when there is not (bzip2's CC/AR/RANLIB).
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

# pkg_pytarget -- point the build-python's sysconfig at the TARGET interpreter
# in the sysroot, so pip and setuptools answer for mipsel while running on
# x86-64. After pkg_toolchain, pkg_deps and pkg_buildpython.
#
# anvil-python ships _sysconfigdata__linux_mipsel-linux-gnu.py, recording the
# cross CC, LDSHARED, EXT_SUFFIX and INCLUDEPY; _PYTHON_SYSCONFIGDATA_NAME
# pointed at it is what makes build_ext build for mipsel. It is rewritten
# first because every path in it is /usr/data/anvil/..., which exists on the
# printer and nowhere here -- blanket over every string value, because that
# list is what nobody gets right by hand: INCLUDEPY fails loudly, LIBDIR and
# LIBPL quietly. Read only by the build, never shipped. Pure-python recipes
# call it too: sysconfig is what a wheel build asks for its tags either way.
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
    # Only the rewritten module, deliberately not the target's stdlib: that
    # puts the host interpreter importing the target's os.py one path-ordering
    # mistake away.
    export PYTHONPATH="$_xsys"
    export PYTHONDONTWRITEBYTECODE=1
    export PIP_DISABLE_PIP_VERSION_CHECK=1
    # setuptools does not forward CFLAGS to its link lines, which is why the
    # ABI flags live in the gcc wrapper. What is passed here only helps a
    # compile find headers.
    export LDSHARED="$PKG_HOST-gcc -shared -L$PKG_PYROOT/lib"
    export CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64 -I$PKG_PYROOT/include -I$PKG_PYINC"
    export CXXFLAGS="$CFLAGS"

    # Where every wheel is unpacked: the recipe's own staging tree, at the
    # path site-packages has on the printer. pkg_ship reads from here.
    PKG_PYSP="$PWD/$PKG_WORK/stage$MODDIR/lib/python$PY_MM/site-packages"
    mkdir -p "$PKG_PYSP"

    # Gated before anything is built on it: if _PYTHON_SYSCONFIGDATA_NAME has
    # not taken, the result is a tree of host objects that builds perfectly
    # and imports nowhere.
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

# pkg_pysrc <list-entry> -- where this package's sdist unpacked to: the file
# name with .tar.gz removed, under $PKG_WORK/src.
pkg_pysrc() {
    _f=$(pypkg_var "$1" FILE)
    printf '%s/src/%s' "$PKG_WORK" "${_f%.tar.gz}"
}

# pkg_pywheel <list-entry> [VAR=VAL ...] -- build one wheel for the target
# from the source pkg_unpack extracted and unpack it into the staging
# site-packages. Trailing VAR=VAL pairs are environment for that build alone.
#   PKG_PY_SETUP_ARGS   drive setup.py build_ext with these and then
#                       bdist_wheel, instead of pip. PEP 517 offers no way to
#                       pass build_ext options, and pillow's --disable-* are.
#
# NOTHING HERE TALKS TO A NETWORK: pip runs --no-index against a tree whose
# sha256 bin/fetch-assets.sh checked, and --no-binary :all: guards against
# x86-64 wheels the day someone adds an index URL. Unzipped rather than
# pip-installed, because `pip install` installs FOR the interpreter running
# it, which is x86-64. .dist-info goes, since nothing on the printer resolves
# a dependency or runs an entry point; the .data directories go because their
# console-script shebangs name the build-python under work/.py-host.
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

# pkg_pynative [count] -- assert this package shipped at least `count`
# (default 1) compiled extension modules. After pkg_ship, so it reads $PKG_OUT.
#
# WHAT IT CATCHES has no other symptom: a package with a native extension AND
# a pure-python fallback, where the extension fails to cross-compile and
# setup.py quietly ships the fallback. Nothing errors, and the printer gets
# the slow path -- or, for cffi and lmdb, nothing that works at all. A count
# and not a list of module names, because the names are upstream's and change
# on a version bump while "this recipe compiles something" must not.
pkg_pynative() {
    _want=${1:-1}
    _got=$(find "$PKG_OUT/lib/python$PY_MM/site-packages" -name '*.so' 2>/dev/null | wc -l)
    [ "$_got" -ge "$_want" ] || pkg_die \
        "$PKG_ID: $_got extension module(s) in site-packages, expected at
         least $_want. The native build fell back to a pure-python wheel --
         see $PKG_LOG/wheel-*.log for the compile that did not happen"
    pkg_say "$PKG_ID: $_got extension module(s)"
}

# pkg_ship <relative-glob> [...] -- copy what the package contains out of the
# staged install into $PKG_OUT, the tree bin/build-packages.sh turns into the
# .ipk. Globs are relative to the prefix inside the DESTDIR, and what a
# package contains depends on what it is for, so each recipe says which files
# rather than taking a default.
#
# cp -a and never plain cp: a shared library is three names, two of them
# symlinks, and the first is the one libnacl's dlopen fallback constructs.
#
# PKG_STRIP_ARGS defaults to --strip-unneeded, keeping the dynamic symbols
# anything will dlsym; set it empty for a plain strip-all. Static archives are
# never stripped -- strip on a .a removes symbols the linker still needs.
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

    # NOR PYTHON BYTECODE. anvil-core stages a directory of .py helpers
    # wholesale, and any test that imports one leaves a __pycache__ beside it
    # -- gitignored, so invisible in a diff, and copied by cp -a. That made
    # package contents depend on whether pytest had run on the build machine.
    # The .pyc are useless anyway: built by the image's python 3.11, where the
    # printer runs 3.13. Swept here because the trap is set for any recipe
    # that stages a directory of .py files.
    find "$PKG_OUT" -name '__pycache__' -type d -prune -exec rm -rf {} + \
        2>/dev/null || true
    find "$PKG_OUT" -name '*.pyc' -delete

    # STATIC ARCHIVES ARE NOT REPRODUCIBLE UNTIL MADE SO. An ar archive stores
    # a per-member mtime and the uid/gid of whoever compiled, and the symbol
    # index carries a timestamp of its own; SOURCE_DATE_EPOCH and opkg-build's
    # `-o 0 -g 0` clamp the tarballs above and reach nothing inside a .a.
    #   objcopy -D   zeroes uid, gid and mtime in the MEMBER headers.
    #   ranlib  -D   rewrites the symbol INDEX with a zeroed header.
    # The cross binutils is 2.27 and its ranlib writes the current timestamp
    # despite -D, so the index is rewritten with the build machine's ranlib;
    # ar is a container format and BFD reads mipsel members fine. Skipped when
    # a recipe never called pkg_toolchain, which qa/replica/test_abi.py
    # backstops.
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
