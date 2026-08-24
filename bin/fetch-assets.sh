#!/usr/bin/env bash
# Download the pinned third-party payload pieces into vendor/.
#
#   ./bin/fetch-assets.sh              whatever BUILD_MAINSAIL / BUILD_HELIX ask for
#   ./bin/fetch-assets.sh --all        both, regardless of those flags
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
    get "https://github.com/Klipper4Creator5/helixscreen/releases/download/$HELIX_VERSION/$HELIX_FILE" \
        "$HELIX_TGZ" "$HELIX_SHA256"
fi

if [ "$ALL" = 1 ] || [ "${BUILD_MOONRAKER:-0}" = "1" ]; then
    # Moonraker ships no release asset, so this is GitHub's generated source
    # tarball. /archive/<ref> takes a tag OR a commit sha, which matters
    # because the pin is currently a commit -- see versions.env for why there
    # is no release we can use. The sha256 is what makes either safe.
    get "https://github.com/Arksine/moonraker/archive/$MOONRAKER_VERSION.tar.gz" \
        "$MOONRAKER_TGZ" "$MOONRAKER_SHA256"
fi
