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
# KLIPPER IS NOT ON THIS LIST any more. BUILD_KLIPPER=stock kept FlashForge's
# v0.12 tree, and every other thing we ship is now written against the fork:
# the ff_*.py extras are anvil-klipper's own files, the ff-*.cfg declare
# sections only they implement, and c_helper.so is built from the tree beside
# it. A stock build was a printer with the mod's configuration and none of the
# code behind it.
#
# Plain defaults, overridable from config.env, which is sourced above.
#
# THE MOD_* SWITCHES ARE GONE -- MOD_WEB, MOD_CAM, MOD_UI, MOD_SSH, MOD_WIFI.
# Every one of them defaulted to 1, and each bought a second state that every
# init script, gate and test then had to reason about: nginx that might not
# run, a camera that might not stream, a screen that might be off on purpose.
# Nobody wanted those states -- what people want when they set one is a stock
# printer, which is one FlashForge package away. What remains configurable is
# what has a real range: the BUILD_* flags below decide what goes IN a build,
# and the MOD_CAM_* and NICE_* values in anvil.conf tune what is running.
#
# FlashForge's firmwareExe is REPLACED, not kept: HelixScreen is the only UI.
# If it will not start, `opkg remove anvil-helixscreen` boots headless.
# ssh and Mainsail are your recovery path if the screen is dark, and
# a USB stick with the STOCK FlashForge package on it is the uninstall for
# everything that came out of a package (`make test-recovery`). Moonraker is
# the exception: it lives only on the factory image, so a reflash cannot put
# FlashForge's back -- see BUILD_MOONRAKER and docs/how-it-works.md.
BUILD_TOOLCHANGE="${BUILD_TOOLCHANGE:-1}"
BUILD_MAINSAIL="${BUILD_MAINSAIL:-1}"
BUILD_MOONRAKER="${BUILD_MOONRAKER:-1}"
BUILD_HELIX="${BUILD_HELIX:-1}"

# Everything we add to the printer lives under this one directory on the DATA
# partition, so a FlashForge OTA cannot delete it. It is a --prefix root and
# not a junk drawer: bin/, lib/, libexec/, etc/ mean what they mean anywhere
# else, and s6 and CPython are both CONFIGURED with this path, so it is baked
# into shipped binaries and moving it means rebuilding them. Defined here
# because the recipes under pkgs/ need the same answer and must not be free to
# give a different one.
MODDIR="${MODDIR:-/usr/data/anvil}"

# Where the payload is assembled, before bin/pack.sh tars it into
# anvil.tar.xz. TWO NAMES because opkg unpacks a package's paths -- which are
# ./usr/data/anvil/... -- relative to the root it is given, so the payload is
# $MODDIR deep inside that root. patch.sh installs into the root and finishes
# the payload; pack.sh only tars the payload.
#
# Here rather than local to patch.sh because pack.sh, the Makefile's clean
# target and test/run-tests.py's teardown all name this tree, and the three
# that only delete it would have failed silently.
PAYLOAD_ROOT="${PAYLOAD_ROOT:-$ROOT/work/modpayload-root}"
PAYLOAD_DIR="${PAYLOAD_DIR:-$PAYLOAD_ROOT$MODDIR}"
export PAYLOAD_ROOT PAYLOAD_DIR

# The Ingenic GLIBC cross-toolchain and its tool prefix: gcc 7.2.0 / glibc
# 2.29 for the X2000, the one that produces this printer's ABI. Used by every
# recipe that compiles, through pkg_toolchain. MIPS_TOOLCHAIN_TGZ below is the
# tarball it is unpacked from; this is where it lands.
PY_HOST="${PY_HOST:-mips-linux-gnu}"
PY_TOOLCHAIN_DIR="${PY_TOOLCHAIN_DIR:-work/.mips-toolchain/mips-gcc720-glibc229}"

# The architecture string stamped into every .ipk this repo builds, and into
# the feed index beside them. See docs/notes/85-packaging.md.
#
# DELIBERATELY NOT AN OpenWrt NAME. OpenWrt's nearest label for this silicon
# is `mipsel_24kc` -- same ISA, same o32 ABI, but musl. Those packages would
# satisfy an opkg dependency here, install without complaint and fail to load
# against the printer's glibc 2.29. A name no public feed uses makes an
# OpenWrt .ipk get refused on architecture, before it is unpacked.
#
# xburst2 is Ingenic's name for the X2000's core. What the string promises is
# the ABI mips_abi_gate checks -- o32, nan2008, mips32r2 -- linked against the
# Ingenic glibc.
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
# Both are consumed by pkgs/klipper; see versions.env for why the pin exists.
KLIPPER_TGZ="${KLIPPER_TGZ:-$ROOT/vendor/klipper-${KLIPPER_VERSION:-unpinned}.tar.gz}"
MIPS_TOOLCHAIN_TGZ="${MIPS_TOOLCHAIN_TGZ:-$ROOT/vendor/${MIPS_TOOLCHAIN_FILE:-mips-toolchain.tar.gz}}"
# The supervision stack: skalibs (s6's own C library), execline (which s6-rc
# links unconditionally), s6 itself and s6-rc. Every package ships these, so
# unlike the Klipper pieces there is no flag that switches them off -- see
# versions.env for why the build is the way it is.
#
# Four tarballs and no cache variable: all four are recipes under pkgs/, so the
# output path is pkg_out's business and staleness is pkg_stale's.
SKALIBS_TGZ="${SKALIBS_TGZ:-$ROOT/vendor/skalibs-${SKALIBS_VERSION:-unpinned}.tar.gz}"
S6_TGZ="${S6_TGZ:-$ROOT/vendor/s6-${S6_VERSION:-unpinned}.tar.gz}"
EXECLINE_TGZ="${EXECLINE_TGZ:-$ROOT/vendor/execline-${EXECLINE_VERSION:-unpinned}.tar.gz}"
S6RC_TGZ="${S6RC_TGZ:-$ROOT/vendor/s6-rc-${S6RC_VERSION:-unpinned}.tar.gz}"

export MAINSAIL_ZIP HELIX_TGZ MOONRAKER_TGZ KLIPPER_TGZ MIPS_TOOLCHAIN_TGZ
export SKALIBS_TGZ S6_TGZ EXECLINE_TGZ S6RC_TGZ

# CPython and the seven C libraries it links against, each pinned here and
# built by its own recipe under pkgs/. Eight tarballs and not one, because
# sqlite, openssl, libffi, xz, bzip2, zlib and expat are separate projects the
# interpreter merely knows how to use, and none of them can be borrowed from
# this printer's rootfs -- which is why the stock 3.8.2 has no sqlite3 module.
#
# The compiler is MIPS_TOOLCHAIN_TGZ above, the Ingenic GLIBC one: a
# musl-linked interpreter cannot dlopen a glibc c_helper.so, and dlopen is
# exactly how klippy loads it. See tools/python/README.md.
PY_TGZ="${PY_TGZ:-$ROOT/vendor/Python-${PY_VERSION:-unpinned}.tgz}"
OPENSSL_TGZ="${OPENSSL_TGZ:-$ROOT/vendor/openssl-${OPENSSL_VERSION:-unpinned}.tar.gz}"
SQLITE_TGZ="${SQLITE_TGZ:-$ROOT/vendor/sqlite-autoconf-${SQLITE_VERSION:-unpinned}.tar.gz}"
ZLIB_TGZ="${ZLIB_TGZ:-$ROOT/vendor/zlib-${ZLIB_VERSION:-unpinned}.tar.gz}"
LIBFFI_TGZ="${LIBFFI_TGZ:-$ROOT/vendor/libffi-${LIBFFI_VERSION:-unpinned}.tar.gz}"
XZ_TGZ="${XZ_TGZ:-$ROOT/vendor/xz-${XZ_VERSION:-unpinned}.tar.gz}"
BZIP2_TGZ="${BZIP2_TGZ:-$ROOT/vendor/bzip2-${BZIP2_VERSION:-unpinned}.tar.gz}"
EXPAT_TGZ="${EXPAT_TGZ:-$ROOT/vendor/expat-${EXPAT_VERSION:-unpinned}.tar.gz}"

# The ABI series CPython names its own directories and binaries after --
# bin/python3.13, lib/python3.13/, config-3.13-mipsel-linux-gnu. Spelled out
# rather than sed'd out of PY_VERSION so that a 3.14 bump is a deliberate
# edit.
PY_MM="${PY_MM:-3.13}"
export PY_MM

export PY_TGZ OPENSSL_TGZ SQLITE_TGZ ZLIB_TGZ LIBFFI_TGZ XZ_TGZ BZIP2_TGZ
export EXPAT_TGZ

# The third-party python packages that become the interpreter's
# site-packages, and libsodium, which libnacl dlopens out of $MODDIR/lib.
#
# The list moves, so these are not one variable per tarball the way everything
# above is: versions.env carries PYPKG_LIST plus a FILE/SHA256 pair per entry,
# and the three helpers below are how both bin/fetch-assets.sh and bin/patch.sh
# read that table. Written once, because a package the fetcher and the builder
# disagree about is a build that downloads one file and compiles another.
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
# time beside it -- a package whose .ipk claims a version it does not contain
# is what a second pin buys. Every sdist on PyPI is <name>-<version>.tar.gz and
# the version is the part after the LAST dash, which is what makes this safe
# for the entries whose file name is not their list name: inotify_simple-1.3.5,
# streaming_form_data-1.19.1, pyserial-asyncio-0.6.
pypkg_version() {
    local _f
    _f="$(pypkg_var "$1" FILE)"
    _f=${_f%.tar.gz}; _f=${_f%.tgz}; _f=${_f%.zip}
    printf '%s' "${_f##*-}"
}
# The sources every recipe under pkgs/ builds from. ZLIB_TGZ is NOT repeated
# here: it is pinned thirty lines up for CPython, and pkgs/3rdparty/zlib builds that same
# tarball once for everybody.
SODIUM_TGZ="${SODIUM_TGZ:-$ROOT/vendor/libsodium-${SODIUM_VERSION:-unpinned}.tar.gz}"
OPKG_TGZ="${OPKG_TGZ:-$ROOT/vendor/opkg-${OPKG_VERSION:-unpinned}.tar.gz}"
LIBARCHIVE_TGZ="${LIBARCHIVE_TGZ:-$ROOT/vendor/libarchive-${LIBARCHIVE_VERSION:-unpinned}.tar.gz}"
export SODIUM_TGZ OPKG_TGZ LIBARCHIVE_TGZ

# WHERE A RECIPE'S OUTPUT LIVES IS DERIVED, NOT NAMED: pkgs/lib.sh's pkg_out
# spells work/pkg/<recipe>, so adding a package is one directory under pkgs/ and
# no edit to this file. These three aliases remain only because bin/patch.sh
# and bin/fetch-assets.sh refer to them. Nothing new should be added below.
SODIUM_BUILD="${SODIUM_BUILD:-$ROOT/work/pkg/libsodium}"
OPKG_BUILD="${OPKG_BUILD:-$ROOT/work/pkg/opkg}"
ZLIB_BUILD="${ZLIB_BUILD:-$ROOT/work/pkg/zlib}"
export SODIUM_BUILD OPKG_BUILD ZLIB_BUILD

# The feed: where bin/build-packages.sh writes .ipk files and the index, and
# where pkgs/lib.sh's pkg_deps reads a recipe's build dependencies back out of.
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
# A FUNCTION, AND POINTED AT THE PAYLOAD rather than at any one build tree: a
# .so staged into $PAYLOAD_DIR by a path the gate did not know about ships
# ungated, and the first machine to notice is a printer. The payload is by
# definition everything that ships.
#
# NOTHING IS EXEMPT, s6 included. A legacy-NaN binary (e_flags 0x1007, from a
# mips32r1 build) looks harmless if you assume the NaN encoding only matters to
# floating point -- but it matters at exec(): a MIPS kernel built nan2008-only
# can refuse to run it outright, or silently misconfigure its FPU mode. Neither
# shows up under qemu-mipsel-static, because user-mode emulation does not
# enforce the ABI check a real kernel's binfmt loader does, which is exactly
# how such a binary once shipped with every replica gate still passing.
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
        # measured: 11 for an 11-member .a, 298 for a host libgcc.a. Reading a
        # single `Flags:` line would hand a multi-line string to a `case`
        # expecting one word, and every .a would fail the gate with an error
        # naming a value nobody could parse. pkgs/3rdparty/zlib and pkgs/3rdparty/skalibs are the
        # recipes that ship an archive.
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
        # A MASK, NOT THE PAIR 0x70001405/0x70001407. Those two are what
        # linked BINARIES read, because crt startup objects happen to set
        # NOREORDER; object files need not. libarchive's xxhash.o comes out
        # 0x70001406 -- identical ABI, no NOREORDER -- and an exact whitelist
        # calls it a wrong-ABI object.
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
