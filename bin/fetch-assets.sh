#!/usr/bin/env bash
# Download the pinned third-party payload pieces into vendor/.
#
#   ./bin/fetch-assets.sh              whatever the BUILD_* flags ask for
#                                      (BUILD_MAINSAIL / BUILD_HELIX / BUILD_MOONRAKER)
#   ./bin/fetch-assets.sh --all        all three, regardless of those flags
#
# Nothing here is committed: the repo stays free of binaries and the versions
# live in versions.env. A cached file with the right sha256 is never
# re-downloaded, so this is a no-op on every build after the first.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/common.sh"
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
    curl -fL --progress-bar -o "$dest.part" "$url"
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
    # Klipper4FlashForge is the org's current name; the old Klipper4Creator5
    # URL only worked through GitHub's rename redirect, which dies the day
    # someone claims the old handle.
    get "https://github.com/Klipper4FlashForge/helixscreen/releases/download/$HELIX_VERSION/$HELIX_FILE" \
        "$HELIX_TGZ" "$HELIX_SHA256"
fi

# The Klipper fork sources and the toolchain that compiles chelper for the
# printer. Skipped when config.env points KLIPPER_FORK at a local checkout:
# that path brings its own tree, and the toolchain tarball is ~203MB.
if [ "$ALL" = 1 ] || { [ "${BUILD_KLIPPER:-0}" = "fork" ] && [ ! -d "${KLIPPER_FORK:-}/klippy" ]; }; then
    get "https://github.com/Klipper4FlashForge/klipper/archive/$KLIPPER_VERSION.tar.gz" \
        "$KLIPPER_TGZ" "$KLIPPER_SHA256"
    get "https://github.com/ballaswag/k1-discovery/releases/download/$MIPS_TOOLCHAIN_VERSION/$MIPS_TOOLCHAIN_FILE" \
        "$MIPS_TOOLCHAIN_TGZ" "$MIPS_TOOLCHAIN_SHA256"
fi

if [ "$ALL" = 1 ] || [ "${BUILD_MOONRAKER:-0}" = "1" ]; then
    # Moonraker ships no release asset, so this is GitHub's generated source
    # tarball. /archive/<ref> takes a tag OR a commit sha, which matters
    # because the pin is currently a commit -- see versions.env for why there
    # is no release we can use. The sha256 is what makes either safe.
    get "https://github.com/Arksine/moonraker/archive/$MOONRAKER_VERSION.tar.gz" \
        "$MOONRAKER_TGZ" "$MOONRAKER_SHA256"
fi

# s6 and skalibs, and the musl cross-toolchain that builds them. Every package
# ships s6, so there is no BUILD_ flag here -- these are fetched on every
# build, not on request.
#
# The two source tarballs are a few hundred KB each and always come down. The
# toolchain is ~100MB, so it is fetched only when bin/patch.sh would actually
# have to compile: work/.s6 caches the cross-built tree between builds and
# names the versions it was built from, so a checkout that already has a
# current one never pulls the compiler at all. (Same shape as the Ingenic
# toolchain above, which is skipped when there is nothing to compile.)
get "https://skarnet.org/software/skalibs/skalibs-$SKALIBS_VERSION.tar.gz" \
    "$SKALIBS_TGZ" "$SKALIBS_SHA256"
get "https://skarnet.org/software/s6/s6-$S6_VERSION.tar.gz" \
    "$S6_TGZ" "$S6_SHA256"
if [ "$ALL" = 1 ] \
   || [ "$(cat "$S6_BUILD/.version" 2>/dev/null || true)" != "$SKALIBS_VERSION $S6_VERSION" ]; then
    # No version in the URL: musl.cc rebuilds this tarball in place, so the
    # sha256 in versions.env is the entire pin. A rebuild upstream stops the
    # build here rather than silently changing the compiler.
    get "https://musl.cc/$MUSL_TOOLCHAIN_FILE" \
        "$MUSL_TOOLCHAIN_TGZ" "$MUSL_TOOLCHAIN_SHA256"
fi
