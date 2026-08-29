#!/usr/bin/env bash
# Download the pinned third-party payload pieces into vendor/.
#   ./bin/fetch-assets.sh [--all]    --all ignores the BUILD_* flags
# Pins live in versions.env; a cached file with the right sha256 is not refetched.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/common.sh"
# Sourced for pkg_needs alone: "is any recipe going to have to compile?" -- the
# question that decides whether the ~203MB toolchain is worth downloading.
# shellcheck disable=SC1091
. "$ROOT/pkgs/lib.sh"
say() { printf '>> %s\n' "$*"; }

ALL=0
[ "${1:-}" = "--all" ] && ALL=1

mkdir -p vendor

# get <url> <destination> <sha256>
get() {
    url="$1"; dest="$2"; want="$3"
    if [ -f "$dest" ]; then
        have=$(sha256sum "$dest" | cut -d' ' -f1)
        if [ "$have" = "$want" ]; then
            say "cached  $(basename "$dest")"
            return 0
        fi
        say "stale   $(basename "$dest") -- re-downloading"
    fi
    say "fetch   $url"
    # --retry: several hosts, and a plain -f turns one bad minute into a failed
    # build. --connect-timeout: without it a silent host burns curl's own
    # default (over a minute) before an attempt even counts as failed.
    curl -fL --progress-bar --connect-timeout 20 \
        --retry 5 --retry-connrefused --retry-all-errors --retry-delay 5 \
        -o "$dest.part" "$url"
    have=$(sha256sum "$dest.part" | cut -d' ' -f1)
    if [ "$want" = "SKIP" ]; then
        mv "$dest.part" "$dest"
        say "sha256  $have  <-- paste this into versions.env"
        return 0
    fi
    if [ "$have" != "$want" ]; then
        rm -f "$dest.part"
        echo "checksum mismatch for $(basename "$dest")" >&2
        echo "  expected $want" >&2
        echo "  got      $have" >&2
        exit 1
    fi
    mv "$dest.part" "$dest"
}

if [ "$ALL" = 1 ] || [ "${BUILD_MAINSAIL:-0}" = "1" ]; then
    get "https://github.com/mainsail-crew/mainsail/releases/download/$MAINSAIL_VERSION/mainsail.zip" \
        "$MAINSAIL_ZIP" "$MAINSAIL_SHA256"
fi

if [ "$ALL" = 1 ] || [ "${BUILD_HELIX:-0}" = "1" ]; then
    # Klipper4FlashForge is the org's current name; the old URL only worked
    # through GitHub's rename redirect.
    get "https://github.com/Klipper4FlashForge/helixscreen/releases/download/$HELIX_VERSION/$HELIX_FILE" \
        "$HELIX_TGZ" "$HELIX_SHA256"
fi

# One source, named once, because pkgs/klipper is a recipe. Re-pin
# KLIPPER_VERSION and KLIPPER_SHA256 to build something else.
get "https://github.com/Klipper4FlashForge/klipper/archive/$KLIPPER_VERSION.tar.gz" \
    "$KLIPPER_TGZ" "$KLIPPER_SHA256"

# The Ingenic glibc toolchain -- ~203MB, shared by every recipe that compiles.
# The condition comes from pkg_needs, the code that writes the recipe stamps,
# rather than a second spelling that drifts.
if [ "$ALL" = 1 ] || pkg_needs; then
    get "https://github.com/ballaswag/k1-discovery/releases/download/$MIPS_TOOLCHAIN_VERSION/$MIPS_TOOLCHAIN_FILE" \
        "$MIPS_TOOLCHAIN_TGZ" "$MIPS_TOOLCHAIN_SHA256"
fi

if [ "$ALL" = 1 ] || [ "${BUILD_MOONRAKER:-0}" = "1" ]; then
    # Moonraker ships no release asset; /archive/<ref> takes a tag or a commit
    # sha, and the pin is a commit. The sha256 is what makes either safe.
    get "https://github.com/Arksine/moonraker/archive/$MOONRAKER_VERSION.tar.gz" \
        "$MOONRAKER_TGZ" "$MOONRAKER_SHA256"
fi

# The supervision stack. No BUILD_ flag: every package ships it.
get "https://skarnet.org/software/skalibs/skalibs-$SKALIBS_VERSION.tar.gz" \
    "$SKALIBS_TGZ" "$SKALIBS_SHA256"
get "https://skarnet.org/software/execline/execline-$EXECLINE_VERSION.tar.gz" \
    "$EXECLINE_TGZ" "$EXECLINE_SHA256"
get "https://skarnet.org/software/s6/s6-$S6_VERSION.tar.gz" \
    "$S6_TGZ" "$S6_SHA256"
get "https://skarnet.org/software/s6-rc/s6-rc-$S6RC_VERSION.tar.gz" \
    "$S6RC_TGZ" "$S6RC_SHA256"

# The compiler is fetched above on the same pkg_needs condition, asked again
# here so a build cannot pull 40MB of source and then stop for want of it.
get "https://www.python.org/ftp/python/$PY_VERSION/Python-$PY_VERSION.tgz" \
    "$PY_TGZ" "$PY_SHA256"
get "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
    "$OPENSSL_TGZ" "$OPENSSL_SHA256"
# sqlite.org files the amalgamation under the YEAR of release, which is nowhere
# in the version number -- hence SQLITE_YEAR.
get "https://www.sqlite.org/$SQLITE_YEAR/sqlite-autoconf-$SQLITE_VERSION.tar.gz" \
    "$SQLITE_TGZ" "$SQLITE_SHA256"
# /fossils/, not the front page: zlib.net moves a release there the moment it
# is superseded, and the front-page URL then 404s for a good pin.
get "https://zlib.net/fossils/zlib-$ZLIB_VERSION.tar.gz" \
    "$ZLIB_TGZ" "$ZLIB_SHA256"
get "https://github.com/libffi/libffi/releases/download/v$LIBFFI_VERSION/libffi-$LIBFFI_VERSION.tar.gz" \
    "$LIBFFI_TGZ" "$LIBFFI_SHA256"
get "https://github.com/tukaani-project/xz/releases/download/v$XZ_VERSION/xz-$XZ_VERSION.tar.gz" \
    "$XZ_TGZ" "$XZ_SHA256"
get "https://sourceware.org/pub/bzip2/bzip2-$BZIP2_VERSION.tar.gz" \
    "$BZIP2_TGZ" "$BZIP2_SHA256"
# EXPAT_TAG, not EXPAT_VERSION: libexpat tags R_2_6_4 but names the file
# expat-2.6.4, so both spellings appear in the one URL.
get "https://github.com/libexpat/libexpat/releases/download/$EXPAT_TAG/expat-$EXPAT_VERSION.tar.gz" \
    "$EXPAT_TGZ" "$EXPAT_SHA256"

# pypi <project> <file> <sha256>
# Only /packages/source/<initial>/<project>/<file> can be composed from a pin;
# the other URL embeds a digest of the file itself. The project name is a
# property of the URL, not the version: `markupsafe` -> MarkupSafe-2.1.5.
pypi() {
    proj="$1"; file="$2"; sha="$3"
    get "https://files.pythonhosted.org/packages/source/$(printf '%.1s' "$proj")/$proj/$file" \
        "$ROOT/vendor/$file" "$sha"
}
# PYPKG_HOST_LIST too: the PEP 517 backends never reach a printer, but they
# produce the objects that do.
for p in $PYPKG_LIST $PYPKG_HOST_LIST; do
    pypi "$p" "$(pypkg_var "$p" FILE)" "$(pypkg_var "$p" SHA256)"
done
get "https://github.com/jedisct1/libsodium/releases/download/$SODIUM_VERSION-RELEASE/libsodium-$SODIUM_VERSION.tar.gz" \
    "$SODIUM_TGZ" "$SODIUM_SHA256"

# --- opkg
# zlib is NOT fetched here: the CPython section already pulls that same pin.
get "https://downloads.yoctoproject.org/releases/opkgs/3rdparty/opkg-$OPKG_VERSION.tar.gz" \
    "$OPKG_TGZ" "$OPKG_SHA256"
get "https://github.com/libarchive/libarchive/releases/download/v$LIBARCHIVE_VERSION/libarchive-$LIBARCHIVE_VERSION.tar.gz" \
    "$LIBARCHIVE_TGZ" "$LIBARCHIVE_SHA256"

# A GIT CLONE, uniquely here, because opkg-utils publishes no release tarball.
# Verified against the commit sha below: a tag can be moved, the sha cannot.
if [ ! -d "$OPKG_UTILS_DIR/.git" ]; then
    say "clone   opkg-utils $OPKG_UTILS_VERSION"
    rm -rf "$OPKG_UTILS_DIR"
    git clone -q https://git.yoctoproject.org/opkg-utils "$OPKG_UTILS_DIR"
fi
( cd "$OPKG_UTILS_DIR"
  # Only if the pinned commit is missing, so the common case is offline.
  git cat-file -e "$OPKG_UTILS_COMMIT^{commit}" 2>/dev/null || git fetch -q origin
  git checkout -q "$OPKG_UTILS_COMMIT"
  have=$(git rev-parse HEAD)
  if [ "$have" != "$OPKG_UTILS_COMMIT" ]; then
      echo "   !! opkg-utils is at $have, not the pinned $OPKG_UTILS_COMMIT" >&2
      exit 1
  fi
  # The sha covers what git tracks and nothing about what was edited in place.
  if [ -n "$(git status --porcelain)" ]; then
      echo "   !! $OPKG_UTILS_DIR has local modifications -- the pinned commit" >&2
      echo "      no longer describes what is in it. Delete it and re-run." >&2
      exit 1
  fi )
say "cached  opkg-utils $OPKG_UTILS_VERSION ($OPKG_UTILS_COMMIT)"

# The toolchain, on the pkg_needs condition that decides whether patch.sh has
# to compile at all. Wrong here is not a slow build but a stopped one.
if [ "$ALL" = 1 ] \
   || pkg_needs; then
    get "https://github.com/ballaswag/k1-discovery/releases/download/$MIPS_TOOLCHAIN_VERSION/$MIPS_TOOLCHAIN_FILE" \
        "$MIPS_TOOLCHAIN_TGZ" "$MIPS_TOOLCHAIN_SHA256"
fi
