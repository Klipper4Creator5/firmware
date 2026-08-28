#!/usr/bin/env bash
# Build one .ipk -- the opkg package format -- out of a staged directory tree.
#
# WHY THIS EXISTS AND WHAT IT DELIBERATELY IS NOT. docs/notes/85-packaging.md
# is the argument; the short version is that neither Alpine nor OpenWrt has a
# binary we can install (Alpine has no mips port at all, OpenWrt's is musl and
# this printer is glibc), so a package manager buys us packaging and installing
# and NOT software. That reduces the choice to which format is cheapest to
# PRODUCE, and .ipk wins by a distance: it is an ar archive of two tarballs and
# a three-byte version file, which is this script, and it needs no keypair, no
# Alpine host and no abuild. An .apk would need the three-concatenated-gzip
# layout and an RSA signature over the control stream before anything could
# read it.
#
# IT IS A TOOL, NOT A RECIPE. It knows nothing about libsodium, about the
# toolchain, or about what is in the tree it is handed. The recipes live in
# pkg/*/ and bin/build-packages.sh drives them. Keeping that line sharp is what
# lets a second package cost a pkg.conf rather than an edit here.
#
#     bin/mkipk.sh --name libsodium --version 1.0.20 --release 1 \
#                  --arch mipsel_xburst2 --prefix /usr/data/anvil \
#                  --root work/.sodium --outdir work/packages \
#                  --description "..." [--depends "..."] [--exclude .version]
#
# Writes $outdir/<name>_<version>-<release>_<arch>.ipk and prints its path.
#
# REPRODUCIBLE BY CONSTRUCTION, because a package whose bytes change when
# nothing changed cannot be compared between two builds, and comparing two
# builds is the only cheap way to prove a pin did what it said. Every source of
# nondeterminism is nailed: tar sorts its entries and zeroes owner, group and
# mtime; gzip is given -n so it stores neither timestamp nor filename; ar runs
# in its own deterministic mode. Two runs over the same tree produce identical
# sha256s -- qa/static/test_ipk.py asserts exactly that, because this comment
# would otherwise rot the first time somebody added a flag.
set -euo pipefail

# 1970. Not a placeholder: SOURCE_DATE_EPOCH is the cross-project convention
# for "the timestamp a reproducible build should pretend it is", and a build
# that wants real dates in its packages sets it. Defaulting it to 0 rather than
# to `date` is the difference between reproducible-by-default and
# reproducible-if-you-remember.
: "${SOURCE_DATE_EPOCH:=0}"

NAME=''
VERSION=''
RELEASE=1
ARCH=''
PREFIX=''
ROOT=''
OUTDIR=''
DESCRIPTION=''
DEPENDS=''
SECTION=libs
PRIORITY=optional
MAINTAINER="anvil <none@example.invalid>"
EXCLUDES=()

die() { echo "mkipk: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --name)        NAME="$2"; shift 2 ;;
        --version)     VERSION="$2"; shift 2 ;;
        --release)     RELEASE="$2"; shift 2 ;;
        --arch)        ARCH="$2"; shift 2 ;;
        --prefix)      PREFIX="$2"; shift 2 ;;
        --root)        ROOT="$2"; shift 2 ;;
        --outdir)      OUTDIR="$2"; shift 2 ;;
        --description) DESCRIPTION="$2"; shift 2 ;;
        --depends)     DEPENDS="$2"; shift 2 ;;
        --section)     SECTION="$2"; shift 2 ;;
        --priority)    PRIORITY="$2"; shift 2 ;;
        --maintainer)  MAINTAINER="$2"; shift 2 ;;
        --exclude)     EXCLUDES+=("$2"); shift 2 ;;
        *) die "unknown option: $1" ;;
    esac
done

for v in NAME VERSION ARCH PREFIX ROOT OUTDIR DESCRIPTION; do
    [ -n "${!v}" ] || die "--${v,,} is required"
done
[ -d "$ROOT" ] || die "--root '$ROOT' is not a directory"
# An absolute prefix, because it becomes a path INSIDE data.tar.gz and opkg
# unpacks that relative to its install root. A relative one would land wherever
# the installer happened to be standing.
case "$PREFIX" in
    /*) ;;
    *) die "--prefix must be absolute, got '$PREFIX'" ;;
esac

# The name opkg and every feed index will know this file by. <name>_<version>_
# <arch>.ipk is not decoration -- opkg-make-index and every OpenWrt feed parse
# it, and bin/build-packages.sh writes it into the index's Filename: field.
IPK="$OUTDIR/${NAME}_${VERSION}-${RELEASE}_${ARCH}.ipk"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- the payload
#
# data.tar.gz holds the tree as it will appear on the printer, so $ROOT's
# contents are laid down under $PREFIX: work/.sodium/lib/libsodium.so.26.2.0
# becomes ./usr/data/anvil/lib/libsodium.so.26.2.0. That full path is the
# reason `opkg install` needs no --prefix of its own later, and the reason a
# package built for this mod can never be installed over the rootfs by
# accident: every path it owns is under /usr/data.
#
# cp -a, not cp: libsodium ships libsodium.so -> .so.26 -> .so.26.2.0, and the
# first of those is the name libnacl's dlopen fallback constructs. A copy that
# dereferenced them would put three identical 400KB files in the package and
# still work, until someone wondered why it had tripled in size.
DATA="$WORK/data"
mkdir -p "$DATA$PREFIX"
cp -a "$ROOT/." "$DATA$PREFIX/"
for pattern in ${EXCLUDES+"${EXCLUDES[@]}"}; do
    find "$DATA$PREFIX" -name "$pattern" -exec rm -rf {} + 2>/dev/null || true
done
# Nothing left to ship is a recipe bug, and a silently empty package is the
# kind that installs fine and explains nothing. `find -type f -o -type l`
# rather than a plain `ls`: everything here may legitimately be a symlink.
[ -n "$(find "$DATA$PREFIX" \( -type f -o -type l \) -print -quit)" ] \
    || die "$ROOT staged nothing under $PREFIX -- empty package refused"

# Installed-Size is what opkg reports and what a `df`-aware installer would
# budget against. Bytes, and the symlinks are counted at their own size the way
# du counts them, which is what every other packaging tool reports too.
ISIZE=$(find "$DATA" \( -type f -o -type l \) -printf '%s\n' | awk '{s+=$1} END{print s+0}')

# --------------------------------------------------------------- the control
#
# The field set opkg actually reads. Description is last because it is the only
# one that may continue onto further lines, and a continuation line is defined
# as one starting with whitespace -- so a field after it would have to be
# unindented and would read as a new stanza in the feed index. Putting it last
# removes the question.
CTRL="$WORK/control"
mkdir -p "$CTRL"
{
    printf 'Package: %s\n' "$NAME"
    printf 'Version: %s-%s\n' "$VERSION" "$RELEASE"
    printf 'Architecture: %s\n' "$ARCH"
    printf 'Maintainer: %s\n' "$MAINTAINER"
    printf 'Section: %s\n' "$SECTION"
    printf 'Priority: %s\n' "$PRIORITY"
    printf 'Installed-Size: %s\n' "$ISIZE"
    [ -n "$DEPENDS" ] && printf 'Depends: %s\n' "$DEPENDS"
    printf 'Description: %s\n' "$DESCRIPTION"
} > "$CTRL/control"

# ------------------------------------------------------------- the three bits
#
# THE MEMBER ORDER IS PART OF THE FORMAT, not a convention: debian-binary
# first, then control.tar.gz, then data.tar.gz. opkg reads the archive
# streaming and gives up on a package whose control follows its data.
printf '2.0\n' > "$WORK/debian-binary"

# --format=gnu, and not the posix/pax default: pax writes an extended header
# with atime and ctime in it for every entry, which is both bigger and
# nondeterministic in exactly the way this file exists to avoid. Every opkg
# reads gnu tar.
TARFLAGS=(--format=gnu --sort=name --owner=0 --group=0 --numeric-owner
          --mtime="@$SOURCE_DATE_EPOCH")

mkdir -p "$OUTDIR"
tar -C "$CTRL" "${TARFLAGS[@]}" -cf - ./control | gzip -n -9 > "$WORK/control.tar.gz"
tar -C "$DATA" "${TARFLAGS[@]}" -cf - ./ | gzip -n -9 > "$WORK/data.tar.gz"

# `ar rD`: D is GNU ar's deterministic mode, which zeroes the per-member
# mtime, uid, gid and mode in the archive header. Without it every .ipk
# carries the second it was built and no two builds compare equal. The
# archive is removed first because `ar r` REPLACES members in an existing
# archive rather than starting a new one -- a rebuild after a rename would
# otherwise leave the old member sitting in the file.
rm -f "$IPK"
( cd "$WORK" && ar rDc "$(basename "$IPK")" debian-binary control.tar.gz data.tar.gz 2>/dev/null )
mv "$WORK/$(basename "$IPK")" "$IPK"

printf '%s\n' "$IPK"
