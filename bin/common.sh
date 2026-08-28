# Sourced by every script in bin/. Resolves the repo root, loads config.env
# and exports the feature flags.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$ROOT"

# CONFIG_ENV=<path> points at a different one. The test suite uses it to run
# against a throwaway config instead of writing over the one you edited.
CONFIG_ENV="${CONFIG_ENV:-$ROOT/config.env}"
if [ ! -f "$CONFIG_ENV" ]; then
    if [ -f config.env.example ]; then
        echo "no config.env -- copy config.env.example and edit the paths:" >&2
        echo "    cp config.env.example config.env" >&2
    fi
    exit 1
fi
# shellcheck disable=SC1090
. "$CONFIG_ENV"

# WHAT GOES INTO THE PACKAGE. There is exactly one build -- the firmware:
# forked Klipper with toolchanger support, Mainsail/Moonraker, ssh, and
# HelixScreen driving the touchscreen in place of FlashForge's UI.
#
# These used to live in profiles/*.env, chosen by a PROFILE variable, back
# when a second "changes nothing, writes a report" package existed alongside
# this one. With one build left the indirection bought nothing but a layer to
# read through, so the flags are plain defaults here and config.env -- sourced
# above -- still overrides any of them. Not an exhaustive list: MOD_CAM and
# MOD_WIFI are defaulted where they are used, in bin/patch.sh, and only
# appear here if config.env sets them.
#
# FlashForge's firmwareExe is REPLACED, not kept: HelixScreen is the only UI.
# If it will not start, set MOD_UI=0 in /usr/data/anvil/anvil.conf to boot
# headless. ssh and Mainsail are your recovery path if the screen is dark, and
# a USB stick with the STOCK FlashForge package on it is the uninstall for
# everything that came out of a package (`make test-recovery`). Moonraker is
# the exception: it lives only on the factory image, so a reflash cannot put
# FlashForge's back -- see BUILD_MOONRAKER and docs/how-it-works.md.
BUILD_KLIPPER="${BUILD_KLIPPER:-fork}"
BUILD_TOOLCHANGE="${BUILD_TOOLCHANGE:-1}"
BUILD_MAINSAIL="${BUILD_MAINSAIL:-1}"
BUILD_MOONRAKER="${BUILD_MOONRAKER:-1}"
BUILD_HELIX="${BUILD_HELIX:-1}"
MOD_SSH="${MOD_SSH:-1}"
MOD_WEB="${MOD_WEB:-1}"
MOD_UI="${MOD_UI:-1}"

# Everything we add to the printer lives under this one directory on the DATA
# partition, so a FlashForge OTA cannot delete it. It is a --prefix root and
# not a junk drawer: bin/, lib/, libexec/, etc/ mean what they mean anywhere
# else, and s6 and CPython are both CONFIGURED with this path, so it is baked
# into shipped binaries and moving it means rebuilding them.
#
# It lives here rather than in bin/patch.sh -- which is where it was, and where
# it was the only definition -- because a package recipe under pkg/ needs the
# same answer and must not be free to give a different one. Two prefixes is a
# payload whose halves disagree about where the payload is.
MODDIR="${MODDIR:-/usr/data/anvil}"

# The Ingenic GLIBC cross-toolchain and its tool prefix: gcc 7.2.0 / glibc
# 2.29 for the X2000, the one that produces this printer's ABI. Used by
# bin/patch.sh section 5c (CPython and its extensions) and by the libsodium
# recipe under pkg/, which is the other reason these moved out of patch.sh --
# see MODDIR above. MIPS_TOOLCHAIN_TGZ below is the tarball it is unpacked
# from; this is where it lands.
PY_HOST="${PY_HOST:-mips-linux-gnu}"
PY_TOOLCHAIN_DIR="${PY_TOOLCHAIN_DIR:-work/.mips-toolchain/mips-gcc720-glibc229}"

# The architecture string stamped into every .ipk this repo builds, and into
# the feed index beside them. See docs/notes/85-packaging.md.
#
# IT IS DELIBERATELY NOT AN OpenWrt NAME, and that is the whole point of
# choosing it by hand. OpenWrt's nearest label for this silicon is
# `mipsel_24kc`, which is the same ISA and the same o32 ABI -- and musl. Every
# OpenWrt feed in the world is full of mipsel_24kc packages that would satisfy
# an opkg dependency here, install without complaint, and then fail to load
# against the printer's glibc 2.29. A name no public feed uses makes that
# category of mistake impossible to make quietly: an OpenWrt .ipk offered to
# our opkg is refused on architecture, before it is unpacked.
#
# xburst2 is Ingenic's name for the X2000's core. What the string actually
# promises is the ABI bin/patch.sh's mips_abi_gate checks -- o32, nan2008,
# mips32r2 -- linked against the Ingenic glibc.
IPK_ARCH="${IPK_ARCH:-mipsel_xburst2}"
export MODDIR PY_HOST PY_TOOLCHAIN_DIR IPK_ARCH

# Third-party payload pieces (Mainsail, HelixScreen, Moonraker). They are
# downloaded on demand rather than vendored, so the repo carries no binaries
# and no binary history. versions.env pins the version and the sha256;
# bin/fetch-assets.sh puts the file in vendor/. Point MAINSAIL_ZIP /
# HELIX_TGZ / MOONRAKER_TGZ at your own build in config.env to override --
# but an explicit path is checksummed like any other, and fetch-assets.sh
# overwrites it with the pinned release when the hash does not match. Put
# your file's own sha256 in versions.env to keep it.
# shellcheck disable=SC1091
[ -f "$ROOT/versions.env" ] && . "$ROOT/versions.env"
MAINSAIL_ZIP="${MAINSAIL_ZIP:-$ROOT/vendor/mainsail-${MAINSAIL_VERSION:-unpinned}.zip}"
HELIX_TGZ="${HELIX_TGZ:-$ROOT/vendor/${HELIX_FILE:-helixscreen.tar.gz}}"
MOONRAKER_TGZ="${MOONRAKER_TGZ:-$ROOT/vendor/moonraker-${MOONRAKER_VERSION:-unpinned}.tar.gz}"
# The Klipper fork tarball and the MIPS toolchain that compiles its chelper.
# Only consumed when KLIPPER_FORK does not point at a local checkout -- see
# versions.env for why the pin exists.
KLIPPER_TGZ="${KLIPPER_TGZ:-$ROOT/vendor/klipper-${KLIPPER_VERSION:-unpinned}.tar.gz}"
MIPS_TOOLCHAIN_TGZ="${MIPS_TOOLCHAIN_TGZ:-$ROOT/vendor/${MIPS_TOOLCHAIN_FILE:-mips-toolchain.tar.gz}}"
# The supervision stack: skalibs (s6's own C library), execline (which s6-rc
# links unconditionally), s6 itself and s6-rc. Every package ships these, so
# unlike the Klipper pieces there is no flag that switches them off -- see
# versions.env for why the build is the way it is.
#
# FOUR TARBALLS AND NO CACHE VARIABLE. There used to be an S6_BUILD here
# naming work/.s6, because patch.sh cross-built s6 itself and the fetcher had
# to know whether that tree was stale. All four are recipes under pkg/ now, so
# the output path is pkg_out's business and staleness is pkg_stale's -- the
# fetcher asks pkg_needs, which asks the code that writes the stamp instead of
# a second copy of it. That is the whole of what S6_STAMP existed to get wrong.
SKALIBS_TGZ="${SKALIBS_TGZ:-$ROOT/vendor/skalibs-${SKALIBS_VERSION:-unpinned}.tar.gz}"
S6_TGZ="${S6_TGZ:-$ROOT/vendor/s6-${S6_VERSION:-unpinned}.tar.gz}"
EXECLINE_TGZ="${EXECLINE_TGZ:-$ROOT/vendor/execline-${EXECLINE_VERSION:-unpinned}.tar.gz}"
S6RC_TGZ="${S6RC_TGZ:-$ROOT/vendor/s6-rc-${S6RC_VERSION:-unpinned}.tar.gz}"

# S6_STAMP USED TO BE DEFINED HERE, and the reason it is not any more is worth
# keeping, because the bug it was written to fix is the reason pkg_stamp exists.
#
# It was the cache key for work/.s6, and it had to be spelled once because two
# files read it: patch.sh stamped the tree with it, and fetch-assets.sh tested
# it to decide whether the 71MB musl toolchain had to come down. They did not
# agree. patch.sh wrote three fields ("$SKALIBS_VERSION $S6_VERSION
# $MUSL_TOOLCHAIN_FILE") and the fetcher compared against two, so the `!=`
# could never be false: every run re-hashed 71MB on a warm vendor/, and the
# comment above that condition described a fast path that had never once been
# taken. Two spellings of one string is not duplication that costs style
# points; it is a condition that silently inverts.
#
# Moving the definition here fixed that instance. Making s6 a recipe removes
# the class: pkg_stamp computes the key from pkg.conf, pkg_stale compares it,
# and fetch-assets.sh calls pkg_needs rather than re-deriving anything. There
# is no second spelling left to drift. The toolchain filename is still in the
# key, for the reason it always was -- the compiler determines the ABI as much
# as the sources do -- but now it is in there once, in pkg_stamp.

export MAINSAIL_ZIP HELIX_TGZ MOONRAKER_TGZ KLIPPER_TGZ MIPS_TOOLCHAIN_TGZ
export SKALIBS_TGZ S6_TGZ EXECLINE_TGZ S6RC_TGZ

# CPython and the seven C libraries it is linked against, all pinned in
# versions.env and all cross-built by bin/patch.sh section 5c. Eight tarballs
# and not one, because there is no such thing as a "CPython with batteries"
# source drop: sqlite, openssl, libffi, xz, bzip2, zlib and expat are separate
# projects the interpreter merely knows how to use, and on this printer NONE
# of them can be borrowed from the rootfs -- which is the whole reason the
# stock 3.8.2 has no sqlite3 module to begin with.
#
# The compiler is MIPS_TOOLCHAIN_TGZ above, the Ingenic GLIBC one, and not the
# musl toolchain s6 is built with. That is not a preference: a musl-linked
# interpreter cannot dlopen a glibc c_helper.so, and dlopen is exactly how
# klippy loads it. See tools/python/README.md.
#
# THERE IS NO PY_BUILD ANY MORE, and its absence is the point. It named
# work/.py313, patch.sh's private cache of a cross-built interpreter, and it
# went the way S6_BUILD went: CPython is pkg/python and its eighteen packages
# are pkg/python-*, so the cache is work/pkg/<recipe> and pkg_out derives that
# name from the recipe. Nothing has to be spelled here for a script to find it.
PY_TGZ="${PY_TGZ:-$ROOT/vendor/Python-${PY_VERSION:-unpinned}.tgz}"
OPENSSL_TGZ="${OPENSSL_TGZ:-$ROOT/vendor/openssl-${OPENSSL_VERSION:-unpinned}.tar.gz}"
SQLITE_TGZ="${SQLITE_TGZ:-$ROOT/vendor/sqlite-autoconf-${SQLITE_VERSION:-unpinned}.tar.gz}"
ZLIB_TGZ="${ZLIB_TGZ:-$ROOT/vendor/zlib-${ZLIB_VERSION:-unpinned}.tar.gz}"
LIBFFI_TGZ="${LIBFFI_TGZ:-$ROOT/vendor/libffi-${LIBFFI_VERSION:-unpinned}.tar.gz}"
XZ_TGZ="${XZ_TGZ:-$ROOT/vendor/xz-${XZ_VERSION:-unpinned}.tar.gz}"
BZIP2_TGZ="${BZIP2_TGZ:-$ROOT/vendor/bzip2-${BZIP2_VERSION:-unpinned}.tar.gz}"
EXPAT_TGZ="${EXPAT_TGZ:-$ROOT/vendor/expat-${EXPAT_VERSION:-unpinned}.tar.gz}"

# The ABI series CPython names its own directories and binaries after --
# bin/python3.13, lib/python3.13/, config-3.13-mipsel-linux-gnu. It is spelled
# out rather than sed'd out of PY_VERSION because it is not a substring of it
# in any interesting sense, and a 3.14 bump has to be a deliberate edit.
#
# HERE rather than in bin/patch.sh, where it used to live, because pkg/python
# and the eighteen pkg/python-* recipes all name these directories too. A
# constant that three scripts need is not patch.sh's local variable.
PY_MM="${PY_MM:-3.13}"
export PY_MM

# THE CACHE KEY FOR CPYTHON IS GONE FROM THIS FILE TOO, and that is the end of
# a bug that took three tries to kill. PY_STAMP was "$PY_VERSION plus the seven
# library versions", written by bin/patch.sh and derived AGAIN, twice, in
# bin/fetch-assets.sh to decide whether the 203MB Ingenic toolchain had to come
# down. All three happened to agree, which is luck: the next person to add an
# eighth library would have had to find all three.
#
# pkg_stamp derives a recipe's key from its dependency graph, so "openssl,
# sqlite, zlib, libffi, xz, bzip2 and expat" is PKG_BUILD_DEPENDS in
# pkg/python/pkg.conf and nothing computes it a second time. bin/fetch-assets.sh
# asks pkg_needs, which is the same code the recipes cache on.
export PY_TGZ OPENSSL_TGZ SQLITE_TGZ ZLIB_TGZ LIBFFI_TGZ XZ_TGZ BZIP2_TGZ
export EXPAT_TGZ

# The third-party python packages that become the interpreter's
# site-packages, and libsodium, which libnacl dlopens out of $MODDIR/lib.
#
# There are eighteen of the former and the list moves, so they are NOT one
# variable per tarball the way everything above is: versions.env carries
# PYPKG_LIST plus a FILE/SHA256 pair per entry, and the three helpers below
# are how both bin/fetch-assets.sh and bin/patch.sh read that table. They live
# here rather than being written twice because a package the fetcher and the
# builder disagree about is a build that downloads one file and compiles
# another -- and because the CACHE KEY has to be computed identically in both
# places or the ~203MB Ingenic toolchain is skipped by the fetcher on exactly
# the build that needs it.
#
# pypkg_var takes the list entry (`streaming-form-data`) and a suffix and
# returns the variable versions.env spells for it
# (PYPKG_STREAMING_FORM_DATA_FILE). Bash indirection, which is why this file
# is only ever sourced by bin/*.sh -- payload/* is busybox ash and has none.
pypkg_var() {
    local _n _v
    _n=$(printf '%s' "$1" | tr 'a-z' 'A-Z' | tr '-' '_')
    _v="PYPKG_${_n}_$2"
    printf '%s' "${!_v-}"
}
# The sdist as bin/fetch-assets.sh leaves it in vendor/.
pypkg_tgz() { printf '%s/vendor/%s' "$ROOT" "$(pypkg_var "$1" FILE)"; }
# The version, READ OUT OF THE PINNED FILE NAME rather than pinned a second
# time beside it. Every sdist on PyPI is <name>-<version>.tar.gz and the
# version is the part after the LAST dash, which is what makes this safe for
# the entries whose file name is not their list name: inotify_simple-1.3.5,
# streaming_form_data-1.19.1, pyserial-asyncio-0.6.
#
# A PYPKG_<NAME>_VERSION line per package would be eighteen more strings to
# keep in agreement with eighteen FILE lines, and the failure when they
# disagreed would be a package whose .ipk claims a version it does not
# contain. One pin, read two ways.
pypkg_version() {
    local _f
    _f="$(pypkg_var "$1" FILE)"
    _f=${_f%.tar.gz}; _f=${_f%.tgz}; _f=${_f%.zip}
    printf '%s' "${_f##*-}"
}
# The sources every recipe under pkg/ builds from. ZLIB_TGZ is NOT repeated
# here: it is pinned thirty lines up for CPython, and pkg/zlib builds that same
# tarball once for everybody. One pin, one build, two consumers -- which is the
# whole point of the packaging work and the reason zlib stopped being an
# invisible detail of two other builds.
SODIUM_TGZ="${SODIUM_TGZ:-$ROOT/vendor/libsodium-${SODIUM_VERSION:-unpinned}.tar.gz}"
OPKG_TGZ="${OPKG_TGZ:-$ROOT/vendor/opkg-${OPKG_VERSION:-unpinned}.tar.gz}"
LIBARCHIVE_TGZ="${LIBARCHIVE_TGZ:-$ROOT/vendor/libarchive-${LIBARCHIVE_VERSION:-unpinned}.tar.gz}"
export SODIUM_TGZ OPKG_TGZ LIBARCHIVE_TGZ

# WHERE A RECIPE'S OUTPUT LIVES IS DERIVED, NOT NAMED. pkg/lib.sh's pkg_out
# spells work/pkg/<recipe>, so adding a package is one directory under pkg/ and
# no edit to this file. These three names remain because bin/patch.sh and
# bin/fetch-assets.sh refer to them, and one alias here is cheaper than the
# same path spelled in four scripts -- but nothing new should be added below.
# There were three schemes for this (work/.sodium named by hand, work/.pkg-$id
# and work/.ipk-$name each derived differently) all describing one recipe.
SODIUM_BUILD="${SODIUM_BUILD:-$ROOT/work/pkg/libsodium}"
OPKG_BUILD="${OPKG_BUILD:-$ROOT/work/pkg/opkg}"
ZLIB_BUILD="${ZLIB_BUILD:-$ROOT/work/pkg/zlib}"
export SODIUM_BUILD OPKG_BUILD ZLIB_BUILD

# The feed: where bin/build-packages.sh writes .ipk files and the index, and
# where pkg/lib.sh's pkg_deps reads a recipe's build dependencies back out of.
# It is a local opkg repository, and it is the interface between recipes --
# which is why the path is defined once here rather than in the script that
# happens to write it.
PKG_FEED="${PKG_FEED:-$ROOT/work/packages}"

# The upstream tools, all three from one pinned checkout: opkg-build makes a
# package, opkg-make-index makes the feed, opkg-unbuild takes a package apart
# again to fill a build sysroot.
#
# OPKG_UTILS_DIR is a git CHECKOUT and not a tarball, because opkg-utils
# publishes no release archive anywhere -- see versions.env. It is the one
# vendor/ entry whose integrity is a commit sha rather than a sha256.
OPKG_UTILS_DIR="${OPKG_UTILS_DIR:-$ROOT/vendor/opkg-utils}"
OPKG_BUILD_BIN="${OPKG_BUILD_BIN:-$OPKG_UTILS_DIR/opkg-build}"
OPKG_INDEX_BIN="${OPKG_INDEX_BIN:-$OPKG_UTILS_DIR/opkg-make-index}"
OPKG_UNBUILD_BIN="${OPKG_UNBUILD_BIN:-$OPKG_UTILS_DIR/opkg-unbuild}"
export PKG_FEED OPKG_UTILS_DIR OPKG_BUILD_BIN OPKG_INDEX_BIN OPKG_UNBUILD_BIN

# Replica-only settings: the factory image and the partition sizes. They exist
# for the tests and never reach a printer, so they live in their own file --
# see test.env.example. Values left in config.env keep working.
TEST_ENV="${TEST_ENV:-$ROOT/test.env}"
# shellcheck disable=SC1090
[ -f "$TEST_ENV" ] && . "$TEST_ENV"

# The version is the release date, today's, as YYYYMMDD. It only appears in the
# outer filename -- the stock installer reads the software component's own
# version, never this one -- so a date says something true about the build,
# where a semver would just be a number nobody remembers to bump.
#
# Set MOD_VER explicitly to pin it: for a reproducible rebuild of an old
# release, or for a second release on the same day (e.g. 20260824b).
MOD_VER="${MOD_VER:-$(date -u +%Y%m%d)}"
export MOD_VER

# Which model are we building for? Packages are model-specific: the two
# stock packages carry different firmwareExe binaries and each refuses to
# install on the other model, so one build can never serve both.
TARGET_MACHINE="${MODEL:-${TARGET_MACHINE:-Creator5Pro}}"
case "$TARGET_MACHINE" in
    Creator5Pro) TARGET_PID=0029; _stock="${STOCK_TGZ_CREATOR5PRO:-}" ;;
    Creator5)    TARGET_PID=0028; _stock="${STOCK_TGZ_CREATOR5:-}" ;;
    *) echo "TARGET_MACHINE must be Creator5 or Creator5Pro (got '$TARGET_MACHINE')" >&2; exit 1 ;;
esac
# An explicit STOCK_TGZ always wins; otherwise use the per-model one.
if [ -z "${STOCK_TGZ:-}" ] && [ -n "$_stock" ]; then
    STOCK_TGZ="$_stock"
fi

# PROG_DUMP is a real /usr/prog for the printer replica. One factory image
# serves both models: only the Pro's was ever published, and the replica
# installs the model's own stock package on top of it, which replaces every
# model-specific file it contains.
export TARGET_MACHINE TARGET_PID STOCK_TGZ PROG_DUMP

# ---------------------------------------------------------------- the ABI gate
# Moved here from bin/patch.sh, which was its only caller until the packaging
# lane arrived. bin/build-packages.sh can produce an .ipk without patch.sh ever
# running -- that is the point of `make packages` -- so the gate has to be
# reachable from both or the packaged copy of a library ships unchecked while
# the tarball's copy does not. Same rule, same two words, one definition.
#
# ABI, over every ELF this build cross-compiles: s6 in 5b below, the
# interpreter and its extensions in 5c, libsodium in 5d. The printer's kernel
# wants nan2008/o32/mips32r2 and says ENOEXEC to anything else, and a
# cross-build that quietly emitted one host object -- or one legacy-NaN
# object, because a flag did not reach one link line -- looks like a clean
# build here. Defined once, up here, because 5b needs it before 5c exists to
# borrow it from.
#
# TWO expected words, not one. 0x70001405 is the measured value for an
# EXECUTABLE; a shared object additionally carries EF_MIPS_PIC (0x2) and so
# reads 0x70001407. That is correct and unavoidable for a DYN -- klippy's own
# c_helper.so has it too -- so a gate that pinned one word would fail on every
# extension module in the tree. s6's own binaries are static EXECs, so they
# want 0x70001405 like the interpreter does.
#
# A FUNCTION, AND POINTED AT THE PAYLOAD. It used to walk $PY_BUILD/bin and
# $PY_BUILD/lib -- the build cache. That was the whole tree while the
# interpreter was the only thing this toolchain produced, and it stopped being
# so the moment site-packages and libsodium arrived: a .so staged into
# $MOD_PAYLOAD by a path the gate did not know about ships ungated, and the
# first machine to notice is a printer. So the rule did not change (it already
# covers a DYN correctly) -- the REACH did, to the staged payload, which is
# the only tree that is by definition everything that ships.
#
# s6 is IN this gate now, not exempt from it. It used to be built by a plain
# mips32r1 musl toolchain and read e_flags=0x1007 (mips1, legacy NaN) -- a
# choice defended here as "no floating point, so the NaN encoding cannot
# matter" for exactly as long as nobody checked what the printer's own kernel
# does with that flag at exec() rather than at runtime. It matters at exec():
# a MIPS kernel built nan2008-only can refuse to run a legacy-NaN binary
# outright, or silently misconfigure its FPU mode, neither of which shows up
# under qemu-mipsel-static -- user-mode emulation does not enforce the same
# ABI check a real kernel's binfmt loader does, which is exactly how s6
# shipped in this state and every replica gate still passed. Section 5b now
# cross-builds with Bootlin's mips32r5el-musl toolchain, whose crt/libc
# objects are nan2008 by construction (mips32r5 has no legacy-NaN silicon to
# be compatible with), restricted to mips32r2 codegen with the same
# gcc-wrapper discipline 5c uses -- so s6 gets exactly the ABI everything else
# on this printer already had to have, checked the same way.
mips_abi_gate() {
    local n=0 f hdr counts total good
    while IFS= read -r f; do
        # readelf itself is the ELF test, rather than comparing the first four
        # bytes to \177ELF: that comparison was a command substitution over
        # arbitrary binary content, and every data file in site-packages that
        # happens to start with a NUL made bash print "warning: command
        # substitution: ignored null byte in input" -- eight lines of noise
        # across a clean build, from the gate that is supposed to be the quiet
        # one. readelf exits non-zero on anything that is not an ELF, which is
        # the same question asked of the tool that has to answer it anyway.
        hdr=$(readelf -h "$f" 2>/dev/null) || continue
        # ONE HEADER PER MEMBER, NOT ONE PER FILE. readelf -h on a static
        # archive prints a full ELF header for every object inside it --
        # measured: 11 for an 11-member .a, 298 for a host libgcc.a. The
        # version of this loop that read a single `Flags:` line therefore
        # handed a multi-line string to a `case` expecting one word, and every
        # .a failed the gate with an error naming a value nobody could parse.
        # That went unnoticed while no package shipped an archive; pkg/zlib and
        # pkg/skalibs are the recipes that ship one.
        #
        # So every header is checked and every header has to conform. Both
        # conditions live on the same awk line because readelf prints them
        # there: `Flags: 0x70001407, noreorder, pic, cpic, nan2008, o32,
        # mips32r2` is one line carrying the word and the hex together, and
        # checking them per-line is what keeps one member's flags from being
        # matched against another member's ISA.
        #
        # 0x7000140[0-7] -- the ABI is the HIGH bits and the low three are not
        # part of it. 0x70001400 is EF_MIPS_ARCH_32R2 | EF_MIPS_ABI_O32 |
        # EF_MIPS_NAN2008, which is the whole of what this gate is for. The
        # bottom three bits are EF_MIPS_NOREORDER (0x1), EF_MIPS_PIC (0x2) and
        # EF_MIPS_CPIC (0x4), none of which says anything about whether the
        # printer's kernel will exec the file.
        #
        # This used to accept exactly 0x70001405 and 0x70001407, and those two
        # values were measured from linked BINARIES -- where crt startup
        # objects happen to set NOREORDER, so every executable and every shared
        # object in the tree read one or the other. Object files need not:
        # libarchive's xxhash.o comes out 0x70001406, identical ABI, no
        # NOREORDER, and the old whitelist called it a wrong-ABI object. The
        # pair was always a proxy for the mask, and it only looked exact while
        # nothing but whole binaries went through here. Packaging a .a is what
        # exposed the difference.
        counts=$(awk '
            /Flags:/ {
                total++
                fl = $2; sub(/,$/, "", fl)
                if (fl ~ /^0x7000140[0-7]$/ \
                    && $0 ~ /nan2008/ && $0 ~ /o32/ && $0 ~ /mips32r2/) good++
            }
            END { print (total + 0), (good + 0) }' <<<"$hdr")
        total=${counts% *}; good=${counts#* }
        # total==0 is a failure and not a pass: it means readelf recognised
        # the file and then found nothing to check, which is the shape of a
        # gate that looks green because it examined nothing.
        if [ "$total" -eq 0 ] || [ "$total" != "$good" ]; then
            echo "   !! $f is not nan2008/o32/mips32r2 with e_flags 0x7000140[0-7]" >&2
            echo "      ($good of $total ELF header(s) conform)" >&2
            readelf -h "$f" 2>&1 | sed 's/^/      /' >&2
            return 1
        fi
        n=$((n + total))
    done < <(find "$@" -type f 2>/dev/null)
    printf '%s' "$n"
}
