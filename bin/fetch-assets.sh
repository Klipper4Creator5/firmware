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
# Sourced for pkg_needs alone, which answers "is any recipe under pkg/ going to
# have to compile something?" -- the question that decides whether the ~203MB
# toolchain is worth downloading. It defines functions and nothing else.
# shellcheck disable=SC1091
. "$ROOT/pkg/lib.sh"
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
    # --retry: this fetches from several hosts and a plain -f turns any one
    # of them having a bad minute into a hard build failure. Written after
    # musl.cc -- the previous source for the s6 toolchain, replaced below
    # over exactly this -- died mid-connect on CI runners often enough to be
    # the norm rather than the exception; kept general because the next flaky
    # host will not announce itself in advance.
    #
    # --connect-timeout: without it, a host that is not answering at all --
    # not refusing, just silent -- makes curl wait on its own default (well
    # over a minute) before it even counts as a failed attempt, so 3 retries
    # can take the better part of ten minutes to give up. 20s is generous for
    # a TCP handshake to a reachable host and turns the same three retries
    # into about a minute and a half of real waiting.
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
    # Klipper4FlashForge is the org's current name; the old Klipper4Creator5
    # URL only worked through GitHub's rename redirect, which dies the day
    # someone claims the old handle.
    get "https://github.com/Klipper4FlashForge/helixscreen/releases/download/$HELIX_VERSION/$HELIX_FILE" \
        "$HELIX_TGZ" "$HELIX_SHA256"
fi

# The Klipper fork sources. Skipped when config.env points KLIPPER_FORK at a
# local checkout: that path brings its own tree.
if [ "$ALL" = 1 ] || { [ "${BUILD_KLIPPER:-0}" = "fork" ] && [ ! -d "${KLIPPER_FORK:-}/klippy" ]; }; then
    get "https://github.com/Klipper4FlashForge/klipper/archive/$KLIPPER_VERSION.tar.gz" \
        "$KLIPPER_TGZ" "$KLIPPER_SHA256"
fi

# The Ingenic glibc toolchain -- ~203MB, with two consumers: chelper (Klipper
# fork only) and every recipe that compiles, which no BUILD_ flag switches off.
# Gating on BUILD_KLIPPER=fork alone would let a BUILD_KLIPPER=stock build from
# a clean vendor/ reach patch.sh's Python step with sources but no compiler,
# and die there instead of here.
#
# The second condition is pkg_needs, which answers for every recipe at once:
# the fetcher computes the cache key with the code that writes it rather than
# in a second spelling that can drift.
if [ "$ALL" = 1 ] \
   || { [ "${BUILD_KLIPPER:-0}" = "fork" ] && [ ! -d "${KLIPPER_FORK:-}/klippy" ]; } \
   || pkg_needs; then
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

# The supervision stack: skalibs, execline, s6, s6-rc. Every package ships
# them, so there is no BUILD_ flag here -- these come down on every build, not
# on request. Four tarballs, well under a megabyte between them.
#
get "https://skarnet.org/software/skalibs/skalibs-$SKALIBS_VERSION.tar.gz" \
    "$SKALIBS_TGZ" "$SKALIBS_SHA256"
get "https://skarnet.org/software/execline/execline-$EXECLINE_VERSION.tar.gz" \
    "$EXECLINE_TGZ" "$EXECLINE_SHA256"
get "https://skarnet.org/software/s6/s6-$S6_VERSION.tar.gz" \
    "$S6_TGZ" "$S6_SHA256"
get "https://skarnet.org/software/s6-rc/s6-rc-$S6RC_VERSION.tar.gz" \
    "$S6RC_TGZ" "$S6RC_SHA256"

# CPython and the seven C libraries it links against. Like s6 there is no
# BUILD_ flag: every package ships the interpreter, so these come down on
# every build. They are ~40MB in total and cached by sha256 like everything
# else, so that is a first-build cost and nothing after it.
#
# The Ingenic toolchain that compiles them is fetched further up, but ONLY on
# the Klipper-fork path -- so it is asked for again here, on the condition
# that decides whether patch.sh has to compile at all. Without this a
# BUILD_KLIPPER=stock build would download 40MB of source and then stop
# because there is no compiler for it, and it would stop halfway through
# patch.sh rather than here where the fix is one command.
#
# The condition is the same version stamp patch.sh writes: work/.py313 holds
# the cross-built tree and names the versions it came from, so a checkout that
# already has a current one pulls neither the ~203MB compiler nor a second
# copy of anything.
get "https://www.python.org/ftp/python/$PY_VERSION/Python-$PY_VERSION.tgz" \
    "$PY_TGZ" "$PY_SHA256"
get "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
    "$OPENSSL_TGZ" "$OPENSSL_SHA256"
# sqlite.org files the amalgamation under the YEAR it was released, which is
# nowhere in the version number -- hence SQLITE_YEAR in versions.env. Get it
# wrong and this 404s rather than fetching the wrong thing, which is the
# failure mode to prefer.
get "https://www.sqlite.org/$SQLITE_YEAR/sqlite-autoconf-$SQLITE_VERSION.tar.gz" \
    "$SQLITE_TGZ" "$SQLITE_SHA256"
# /fossils/ and not the front page: zlib.net moves a release there the moment
# it is superseded, and the front-page URL then 404s for a pin that was
# perfectly good yesterday. The fossils path is stable for both.
get "https://zlib.net/fossils/zlib-$ZLIB_VERSION.tar.gz" \
    "$ZLIB_TGZ" "$ZLIB_SHA256"
get "https://github.com/libffi/libffi/releases/download/v$LIBFFI_VERSION/libffi-$LIBFFI_VERSION.tar.gz" \
    "$LIBFFI_TGZ" "$LIBFFI_SHA256"
get "https://github.com/tukaani-project/xz/releases/download/v$XZ_VERSION/xz-$XZ_VERSION.tar.gz" \
    "$XZ_TGZ" "$XZ_SHA256"
get "https://sourceware.org/pub/bzip2/bzip2-$BZIP2_VERSION.tar.gz" \
    "$BZIP2_TGZ" "$BZIP2_SHA256"
# EXPAT_TAG, not EXPAT_VERSION: libexpat tags releases R_2_6_4 and names the
# file expat-2.6.4, so both spellings appear in the one URL.
get "https://github.com/libexpat/libexpat/releases/download/$EXPAT_TAG/expat-$EXPAT_VERSION.tar.gz" \
    "$EXPAT_TGZ" "$EXPAT_SHA256"

# The third-party packages that become the interpreter's site-packages, and
# libsodium. Same rule as the eight tarballs above and for the same reason:
# every package ships them, so there is no BUILD_ flag and no condition --
# they come down once and the sha256 cache means never again. 53MB, of which
# 46MB is pillow's sdist alone (it carries its own test images; there is no
# smaller sdist to have).
#
# pypi <project> <file> <sha256>
#
# files.pythonhosted.org publishes every sdist at TWO urls: the hashed
# /packages/<a>/<b>/<64 hex>/<file> one that a browser copies, and this
# /packages/source/<initial>/<project>/<file> one. Only the second can be
# composed from a pin, because the first embeds a digest of the file itself --
# so bumping a version there means pasting a URL nobody can check by reading.
# The project name is the one thing not in versions.env, because it is a
# property of the URL and not of the version: `smart-open` publishes
# smart_open-6.4.0.tar.gz, `markupsafe` publishes MarkupSafe-2.1.5.tar.gz.
# Same division of labour as EXPAT_TAG above.
pypi() {
    proj="$1"; file="$2"; sha="$3"
    get "https://files.pythonhosted.org/packages/source/$(printf '%.1s' "$proj")/$proj/$file" \
        "$ROOT/vendor/$file" "$sha"
}
# PYPKG_HOST_LIST too: the PEP 517 backends never reach a printer, but they
# are what RUNS on the build machine to produce the objects that do, so they
# are fetched and checked exactly like the rest.
for p in $PYPKG_LIST $PYPKG_HOST_LIST; do
    pypi "$p" "$(pypkg_var "$p" FILE)" "$(pypkg_var "$p" SHA256)"
done
get "https://github.com/jedisct1/libsodium/releases/download/$SODIUM_VERSION-RELEASE/libsodium-$SODIUM_VERSION.tar.gz" \
    "$SODIUM_TGZ" "$SODIUM_SHA256"

# --------------------------------------------------------------------- opkg
# The package manager and its two build-only dependencies. See
# docs/notes/85-packaging.md; versions.env says why 0.7.0 and not 0.6.3.
#
# zlib is NOT fetched here: it is the same pinned tarball the CPython section
# above already pulls (ZLIB_TGZ), and asking for it twice is how two pins that
# are supposed to be one drift apart.
get "https://downloads.yoctoproject.org/releases/opkg/opkg-$OPKG_VERSION.tar.gz" \
    "$OPKG_TGZ" "$OPKG_SHA256"
get "https://github.com/libarchive/libarchive/releases/download/v$LIBARCHIVE_VERSION/libarchive-$LIBARCHIVE_VERSION.tar.gz" \
    "$LIBARCHIVE_TGZ" "$LIBARCHIVE_SHA256"

# opkg-utils: opkg-build and opkg-make-index, which bin/build-packages.sh
# drives instead of assembling .ipk archives itself.
#
# A GIT CLONE AND NOT A `get`, uniquely in this file, and not by choice:
# opkg-utils publishes no release tarball anywhere. Upstream's cgit has
# snapshots disabled and the GitHub mirror has been dead since 2012 --
# versions.env has the full account. So the integrity check is git's own: a
# commit sha is a hash of the entire tree, which is the same guarantee every
# sha256 above provides, and it is verified below rather than assumed from the
# tag. A tag can be moved; the sha it has to resolve to cannot.
if [ ! -d "$OPKG_UTILS_DIR/.git" ]; then
    say "clone   opkg-utils $OPKG_UTILS_VERSION"
    rm -rf "$OPKG_UTILS_DIR"
    git clone -q https://git.yoctoproject.org/opkg-utils "$OPKG_UTILS_DIR"
fi
( cd "$OPKG_UTILS_DIR"
  # Fetch only if the pinned commit is not already here, so the common case is
  # offline and instant.
  git cat-file -e "$OPKG_UTILS_COMMIT^{commit}" 2>/dev/null || git fetch -q origin
  git checkout -q "$OPKG_UTILS_COMMIT"
  have=$(git rev-parse HEAD)
  if [ "$have" != "$OPKG_UTILS_COMMIT" ]; then
      echo "   !! opkg-utils is at $have, not the pinned $OPKG_UTILS_COMMIT" >&2
      exit 1
  fi
  # A dirty checkout is a build whose tooling nobody can name. The sha covers
  # what git tracks and says nothing about what someone edited in place.
  if [ -n "$(git status --porcelain)" ]; then
      echo "   !! $OPKG_UTILS_DIR has local modifications -- the pinned commit" >&2
      echo "      no longer describes what is in it. Delete it and re-run." >&2
      exit 1
  fi )
say "cached  opkg-utils $OPKG_UTILS_VERSION ($OPKG_UTILS_COMMIT)"

# The Ingenic toolchain, on the condition that decides whether patch.sh has to
# compile at all. ONE question, asked of pkg_needs, because everything built
# with this compiler is a recipe under pkg/ now -- the interpreter, its
# eighteen site-packages, libsodium, the s6 family and the rest.
#
# A hand-written comparison here would be a second spelling of a recipe's cache
# key -- which has to include its toolchain and its dependencies -- and the
# second spelling is the one that drifts. Asking the code that WRITES the stamp
# is the only spelling that cannot.
#
# Getting this wrong is not a slow build, it is a stopped one: patch.sh would
# get 53MB of sdists and then halt for want of a compiler, halfway through,
# rather than here where the fix is one command.
if [ "$ALL" = 1 ] \
   || pkg_needs; then
    get "https://github.com/ballaswag/k1-discovery/releases/download/$MIPS_TOOLCHAIN_VERSION/$MIPS_TOOLCHAIN_FILE" \
        "$MIPS_TOOLCHAIN_TGZ" "$MIPS_TOOLCHAIN_SHA256"
fi
