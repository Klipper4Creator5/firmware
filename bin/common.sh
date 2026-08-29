ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
cd "$ROOT"

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

BUILD_TOOLCHANGE="${BUILD_TOOLCHANGE:-1}"
BUILD_MAINSAIL="${BUILD_MAINSAIL:-1}"
BUILD_MOONRAKER="${BUILD_MOONRAKER:-1}"
BUILD_HELIX="${BUILD_HELIX:-1}"

# A --prefix root on the DATA partition, so a FlashForge OTA cannot delete it.
# s6 and CPython are configured with this path, so moving it rebuilds them.
MODDIR="${MODDIR:-/usr/data/anvil}"

# Two names because opkg unpacks a package's ./usr/data/anvil/... paths relative
# to the root it is given: the payload sits $MODDIR deep inside PAYLOAD_ROOT.
PAYLOAD_ROOT="${PAYLOAD_ROOT:-$ROOT/work/modpayload-root}"
PAYLOAD_DIR="${PAYLOAD_DIR:-$PAYLOAD_ROOT$MODDIR}"
export PAYLOAD_ROOT PAYLOAD_DIR

PY_HOST="${PY_HOST:-mips-linux-gnu}"
PY_TOOLCHAIN_DIR="${PY_TOOLCHAIN_DIR:-work/.mips-toolchain/mips-gcc720-glibc229}"

# Deliberately not an OpenWrt name: mipsel_24kc is musl, so such an .ipk would
# satisfy a dependency here, install cleanly and fail against glibc 2.29. An
# unknown name gets it refused on architecture instead.
IPK_ARCH="${IPK_ARCH:-mipsel_xburst2}"
export MODDIR PY_HOST PY_TOOLCHAIN_DIR IPK_ARCH

# Downloaded on demand, pinned in versions.env. An explicit override path is
# checksummed too and replaced when the hash differs -- put its own sha256 there.
# shellcheck disable=SC1091
[ -f "$ROOT/versions.env" ] && . "$ROOT/versions.env"
MAINSAIL_ZIP="${MAINSAIL_ZIP:-$ROOT/vendor/mainsail-${MAINSAIL_VERSION:-unpinned}.zip}"
HELIX_TGZ="${HELIX_TGZ:-$ROOT/vendor/${HELIX_FILE:-helixscreen.tar.gz}}"
MOONRAKER_TGZ="${MOONRAKER_TGZ:-$ROOT/vendor/moonraker-${MOONRAKER_VERSION:-unpinned}.tar.gz}"
KLIPPER_TGZ="${KLIPPER_TGZ:-$ROOT/vendor/klipper-${KLIPPER_VERSION:-unpinned}.tar.gz}"
MIPS_TOOLCHAIN_TGZ="${MIPS_TOOLCHAIN_TGZ:-$ROOT/vendor/${MIPS_TOOLCHAIN_FILE:-mips-toolchain.tar.gz}}"
SKALIBS_TGZ="${SKALIBS_TGZ:-$ROOT/vendor/skalibs-${SKALIBS_VERSION:-unpinned}.tar.gz}"
S6_TGZ="${S6_TGZ:-$ROOT/vendor/s6-${S6_VERSION:-unpinned}.tar.gz}"
EXECLINE_TGZ="${EXECLINE_TGZ:-$ROOT/vendor/execline-${EXECLINE_VERSION:-unpinned}.tar.gz}"
S6RC_TGZ="${S6RC_TGZ:-$ROOT/vendor/s6-rc-${S6RC_VERSION:-unpinned}.tar.gz}"

export MAINSAIL_ZIP HELIX_TGZ MOONRAKER_TGZ KLIPPER_TGZ MIPS_TOOLCHAIN_TGZ
export SKALIBS_TGZ S6_TGZ EXECLINE_TGZ S6RC_TGZ

# Built with the GLIBC toolchain above: a musl-linked interpreter cannot dlopen
# a glibc c_helper.so, and dlopen is how klippy loads it.
PY_TGZ="${PY_TGZ:-$ROOT/vendor/Python-${PY_VERSION:-unpinned}.tgz}"
OPENSSL_TGZ="${OPENSSL_TGZ:-$ROOT/vendor/openssl-${OPENSSL_VERSION:-unpinned}.tar.gz}"
SQLITE_TGZ="${SQLITE_TGZ:-$ROOT/vendor/sqlite-autoconf-${SQLITE_VERSION:-unpinned}.tar.gz}"
ZLIB_TGZ="${ZLIB_TGZ:-$ROOT/vendor/zlib-${ZLIB_VERSION:-unpinned}.tar.gz}"
LIBFFI_TGZ="${LIBFFI_TGZ:-$ROOT/vendor/libffi-${LIBFFI_VERSION:-unpinned}.tar.gz}"
XZ_TGZ="${XZ_TGZ:-$ROOT/vendor/xz-${XZ_VERSION:-unpinned}.tar.gz}"
BZIP2_TGZ="${BZIP2_TGZ:-$ROOT/vendor/bzip2-${BZIP2_VERSION:-unpinned}.tar.gz}"
EXPAT_TGZ="${EXPAT_TGZ:-$ROOT/vendor/expat-${EXPAT_VERSION:-unpinned}.tar.gz}"

# Spelled out rather than derived from PY_VERSION so a 3.14 bump is deliberate.
PY_MM="${PY_MM:-3.13}"
export PY_MM

export PY_TGZ OPENSSL_TGZ SQLITE_TGZ ZLIB_TGZ LIBFFI_TGZ XZ_TGZ BZIP2_TGZ
export EXPAT_TGZ

# pypkg_var maps a PYPKG_LIST entry plus a suffix to the variable versions.env
# spells for it (streaming-form-data -> PYPKG_STREAMING_FORM_DATA_FILE), by bash
# indirection -- which is why this file is never sourced by payload/*'s ash.
pypkg_var() {
    local _n _v
    _n=$(printf '%s' "$1" | tr 'a-z' 'A-Z' | tr '-' '_')
    _v="PYPKG_${_n}_$2"
    printf '%s' "${!_v-}"
}
# Version taken from the pinned file name, after the LAST dash -- which is what
# makes inotify_simple-1.3.5 and pyserial-asyncio-0.6 both come out right.
pypkg_version() {
    local _f
    _f="$(pypkg_var "$1" FILE)"
    _f=${_f%.tar.gz}; _f=${_f%.tgz}; _f=${_f%.zip}
    printf '%s' "${_f##*-}"
}
# ZLIB_TGZ is pinned above for CPython; pkgs/3rdparty/zlib builds it once for all.
SODIUM_TGZ="${SODIUM_TGZ:-$ROOT/vendor/libsodium-${SODIUM_VERSION:-unpinned}.tar.gz}"
OPKG_TGZ="${OPKG_TGZ:-$ROOT/vendor/opkg-${OPKG_VERSION:-unpinned}.tar.gz}"
LIBARCHIVE_TGZ="${LIBARCHIVE_TGZ:-$ROOT/vendor/libarchive-${LIBARCHIVE_VERSION:-unpinned}.tar.gz}"
export SODIUM_TGZ OPKG_TGZ LIBARCHIVE_TGZ

# Output paths are derived by pkgs/lib.sh's pkg_out; these three aliases remain
# only because patch.sh and fetch-assets.sh name them. Add nothing here.
SODIUM_BUILD="${SODIUM_BUILD:-$ROOT/work/pkg/libsodium}"
OPKG_BUILD="${OPKG_BUILD:-$ROOT/work/pkg/opkg}"
ZLIB_BUILD="${ZLIB_BUILD:-$ROOT/work/pkg/zlib}"
export SODIUM_BUILD OPKG_BUILD ZLIB_BUILD

PKG_FEED="${PKG_FEED:-$ROOT/work/packages}"

# A git checkout, not a tarball: opkg-utils publishes no release archive, so its
# integrity is a commit sha rather than a sha256.
OPKG_UTILS_DIR="${OPKG_UTILS_DIR:-$ROOT/vendor/opkg-utils}"
OPKG_BUILD_BIN="${OPKG_BUILD_BIN:-$OPKG_UTILS_DIR/opkg-build}"
OPKG_INDEX_BIN="${OPKG_INDEX_BIN:-$OPKG_UTILS_DIR/opkg-make-index}"
OPKG_UNBUILD_BIN="${OPKG_UNBUILD_BIN:-$OPKG_UTILS_DIR/opkg-unbuild}"
export PKG_FEED OPKG_UTILS_DIR OPKG_BUILD_BIN OPKG_INDEX_BIN OPKG_UNBUILD_BIN

TEST_ENV="${TEST_ENV:-$ROOT/test.env}"
# shellcheck disable=SC1090
[ -f "$TEST_ENV" ] && . "$TEST_ENV"

# The release date, and only ever in the outer filename. Set MOD_VER to pin it.
MOD_VER="${MOD_VER:-$(date -u +%Y%m%d)}"
export MOD_VER

# Each stock package carries its own firmwareExe and refuses the other model.
TARGET_MACHINE="${MODEL:-${TARGET_MACHINE:-Creator5Pro}}"
case "$TARGET_MACHINE" in
    Creator5Pro) TARGET_PID=0029; _stock="${STOCK_TGZ_CREATOR5PRO:-}" ;;
    Creator5)    TARGET_PID=0028; _stock="${STOCK_TGZ_CREATOR5:-}" ;;
    *) echo "TARGET_MACHINE must be Creator5 or Creator5Pro (got '$TARGET_MACHINE')" >&2; exit 1 ;;
esac
if [ -z "${STOCK_TGZ:-}" ] && [ -n "$_stock" ]; then
    STOCK_TGZ="$_stock"
fi

# One factory image serves both models; the replica installs the model's own
# stock package over it.
export TARGET_MACHINE TARGET_PID STOCK_TGZ PROG_DUMP
