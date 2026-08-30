#!/usr/bin/env bash
# Build every recipe under pkgs/ into the feed, in dependency order, and index
# it.
#
#     ./bin/build-packages.sh              all recipes
#     ./bin/build-packages.sh opkg         that one and everything it needs
#
# Each recipe is packaged before the next is built, because a recipe gets its
# PKG_BUILD_DEPENDS out of this feed. The archives are opkg-utils' work; what
# is left here is laying out the tree it packages.
#
# Needs no stock FlashForge package, unlike bin/patch.sh, so packaging stays
# runnable in CI on a bare checkout.
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$ROOT/pkgs/lib.sh"

say() { printf '>> %s\n' "$*"; }

for t in "$OPKG_BUILD_BIN" "$OPKG_INDEX_BIN" "$OPKG_UNBUILD_BIN"; do
    [ -x "$t" ] || { echo "!! $t is missing -- run ./bin/fetch-assets.sh" >&2; exit 1; }
done

# Reproducible by default: opkg-build adds --clamp-mtime when SOURCE_DATE_EPOCH
# is set. THE DEFAULT IS 1 AND NOT 0, WHICH IS NOT A TYPO -- OpenSSL reads it
# as `$ENV{'SOURCE_DATE_EPOCH'} || time()`, and Perl's || makes 0 the one
# value that silently falls through to the current time.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1}"

# Sorted so a dependency precedes its dependent -- alphabetically, libarchive
# comes before the zlib it needs.
if [ $# -gt 0 ]; then
    REQUESTED=("$@")
else
    mapfile -t REQUESTED < <(pkg_recipes)
fi
[ ${#REQUESTED[@]} -gt 0 ] || { echo "no recipes under pkgs/" >&2; exit 1; }
read -r -a RECIPES <<< "$(pkg_order "${REQUESTED[@]}")"

say "order: ${RECIPES[*]}"
mkdir -p "$PKG_FEED"

for r in "${RECIPES[@]}"; do
    _d=$(pkg_dir "$r") \
        || { echo "!! no recipe named '$r'" >&2; exit 1; }
    [ -f "$_d/build.sh" ] || { echo "!! $_d has no build.sh" >&2; exit 1; }

    # Caches on the recipe's own stamp (pkg_begin), so a no-op on a warm tree.
    bash "$_d/build.sh"

    # A subshell per recipe: PKG_DEPENDS leaking into the next one is a package
    # declaring a dependency nobody wrote.
    (
        pkg_conf "$r"

        for v in PKG_NAME PKG_VERSION PKG_ROOT PKG_DESCRIPTION; do
            [ -n "${!v}" ] || { echo "!! $r's pkg.conf leaves $v empty" >&2; exit 1; }
        done
        [ -d "$PKG_ROOT" ] || {
            echo "!! $r: PKG_ROOT '$PKG_ROOT' does not exist -- did build.sh run?" >&2
            exit 1; }

        # --- the layout
        # opkg-build packages a DIRECTORY: the tree as it appears on the
        # target, plus a CONTROL/ it does not ship. Laid down under $MODDIR so
        # `opkg install` needs no prefix. cp -a, not cp: libsodium's
        # .so -> .so.26 -> .so.26.2.0 chain would become three 400KB files.
        LAYOUT="work/.ipk-$PKG_NAME"
        rm -rf "$LAYOUT"
        mkdir -p "$LAYOUT$MODDIR" "$LAYOUT/CONTROL"
        cp -a "$PKG_ROOT/." "$LAYOUT$MODDIR/"
        # -maxdepth 1: PKG_EXCLUDE is always ".version", the stamp pkg_end
        # writes at a recipe's ROOT, but `find -name` matches a basename at
        # any depth -- and Mainsail ships its own www/mainsail/.version, which
        # this deleted.
        # shellcheck disable=SC2086
        for p in $PKG_EXCLUDE; do
            find "$LAYOUT$MODDIR" -maxdepth 1 -name "$p" -exec rm -rf {} + 2>/dev/null || true
        done
        [ -n "$(find "$LAYOUT$MODDIR" \( -type f -o -type l \) -print -quit)" ] \
            || { echo "!! $r staged nothing -- empty package refused" >&2; exit 1; }

        # --- the runtime/dev split
        # PKG_DEV_FILES is MOVED, not copied: a file two packages own is resolved
        # by letting whichever installed last win, silently.
        DEVLAYOUT="work/.ipk-$PKG_NAME-dev"
        rm -rf "$DEVLAYOUT"
        if [ -n "$PKG_DEV_FILES" ]; then
            mkdir -p "$DEVLAYOUT$MODDIR" "$DEVLAYOUT/CONTROL"
            # shellcheck disable=SC2086
            for g in $PKG_DEV_FILES; do
                for m in "$LAYOUT$MODDIR"/$g; do
                    [ -e "$m" ] || continue
                    rel=${m#"$LAYOUT$MODDIR"/}
                    mkdir -p "$DEVLAYOUT$MODDIR/$(dirname "$rel")"
                    mv "$m" "$DEVLAYOUT$MODDIR/$rel"
                done
            done
            [ -n "$(find "$DEVLAYOUT$MODDIR" \( -type f -o -type l \) -print -quit)" ] \
                || { echo "!! $r sets PKG_DEV_FILES and none of it matched" >&2; exit 1; }
            # Or every printer ships an empty include/.
            find "$LAYOUT$MODDIR" -type d -empty -delete 2>/dev/null || true
        fi

        # --- deterministic modes
        # -o 0 -g 0 and SOURCE_DATE_EPOCH settle owner and mtime but not MODE:
        # GNU tar restores a directory's exact mode as root and applies the
        # umask otherwise, so Moonraker came out 0775 in the container and
        # 0755 outside. Symlinks are left alone -- chmod would follow them.
        for lay in "$LAYOUT" "$DEVLAYOUT"; do
            [ -d "$lay$MODDIR" ] || continue
            find "$lay$MODDIR" -type d -exec chmod 0755 {} +
            find "$lay$MODDIR" -type f -perm -u+x -exec chmod 0755 {} +
            find "$lay$MODDIR" -type f ! -perm -u+x -exec chmod 0644 {} +
        done

        # emit <layout> <name> <section> <depends> <description>
        # Description LAST: it is the only field that may continue onto further
        # lines, so any field after it would begin the next stanza.
        emit() {
            _lay=$1; _nm=$2; _sect=$3; _dep=$4; _desc=$5
            # ONE LINE: a raw newline in a control field is a new stanza to some
            # parsers and a continuation to others. Unquoted, so it re-splits.
            # shellcheck disable=SC2086
            _dep=$(echo $_dep)
            {
                printf 'Package: %s\n' "$_nm"
                printf 'Version: %s-%s\n' "$PKG_VERSION" "$PKG_RELEASE"
                printf 'Architecture: %s\n' "$PKG_ARCH"
                printf 'Maintainer: %s\n' "$PKG_MAINTAINER"
                printf 'Section: %s\n' "$_sect"
                printf 'Priority: optional\n'
                [ -n "$_dep" ] && printf 'Depends: %s\n' "$_dep"
                # Provides alone lets a printer install BOTH chamber configs,
                # and the last to unpack wins silently; Conflicts on the same
                # virtual name is what makes "either" mean "exactly one".
                # shellcheck disable=SC2086
                [ -n "$PKG_PROVIDES" ] \
                    && printf 'Provides: %s\n' "$(echo $PKG_PROVIDES)"
                # shellcheck disable=SC2086
                [ -n "$PKG_CONFLICTS" ] \
                    && printf 'Conflicts: %s\n' "$(echo $PKG_CONFLICTS)"
                printf 'Description: %s\n' "$_desc"
            } > "$_lay/CONTROL/control"

            # Runtime package only: a postinst on the -dev half would act on a
            # payload that is not its own. It also runs on the BUILD, with
            # IPKG_INSTROOT empty, so one here guards on something only a
            # printer has.
            if [ "$_nm" = "$PKG_NAME" ] && [ -d "$PKG_DIR/control" ]; then
                for _cs in "$PKG_DIR"/control/*; do
                    [ -f "$_cs" ] || continue
                    cp -f "$_cs" "$_lay/CONTROL/$(basename "$_cs")"
                    case "$(basename "$_cs")" in
                        conffiles) ;;
                        *) chmod +x "$_lay/CONTROL/$(basename "$_cs")" ;;
                    esac
                done
            fi

            # BOTH PATHS ABSOLUTE is a requirement: opkg-build reads its scratch
            # dir from inside a `cd $pkg_dir/CONTROL`, so a relative destination
            # dies on a missing control_list.
            "$OPKG_BUILD_BIN" -o 0 -g 0 "$PWD/$_lay" "$PKG_FEED" > /dev/null
            rm -rf "$_lay"

            _ipk="$PKG_FEED/${_nm}_${PKG_VERSION}-${PKG_RELEASE}_${PKG_ARCH}.ipk"
            [ -f "$_ipk" ] || { echo "!! opkg-build produced no $_ipk" >&2; exit 1; }
            say "$_nm: $(basename "$_ipk") ($(du -h "$_ipk" | cut -f1))"
        }

        # Unless the split took everything -- normal for a link-only library.
        if [ -n "$(find "$LAYOUT$MODDIR" \( -type f -o -type l \) -print -quit)" ]; then
            emit "$LAYOUT" "$PKG_NAME" "$PKG_SECTION" "$PKG_DEPENDS" "$PKG_DESCRIPTION"
        else
            rm -rf "$LAYOUT"
        fi

        # By name: the dev half's headers describe that build of the library.
        if [ -d "$DEVLAYOUT/CONTROL" ]; then
            if [ -f "$PKG_FEED/${PKG_NAME}_${PKG_VERSION}-${PKG_RELEASE}_${PKG_ARCH}.ipk" ]; then
                _devdep="$PKG_NAME"
            else
                _devdep=""
            fi
            emit "$DEVLAYOUT" "$PKG_NAME-dev" libdevel "$_devdep" \
                 "${PKG_DEV_DESCRIPTION:-Headers and static library for $PKG_NAME. Nothing installs this on a printer; it exists to be built against.}"
        fi
    )
done

# --- the prune
# An orphan .ipk goes into the index and a printer can install a package no
# recipe builds any more. Full builds only, and the expected set comes from
# ALL recipes, not the ones this run built.
if [ $# -eq 0 ]; then
    expected=""
    for r in $(pkg_recipes); do
        for v in '' dev; do
            expected="$expected $(basename "$(pkg_ipk "$r" "$v")")"
        done
    done
    for f in "$PKG_FEED"/*.ipk; do
        [ -e "$f" ] || continue
        case " $expected " in
            *" $(basename "$f") "*) continue ;;
        esac
        say "prune: $(basename "$f") -- no recipe produces this any more"
        rm -f "$f"
    done
fi

# --- the index
# opkg refuses a package whose sha256 does not match its stanza, so signing
# the INDEX signs the whole feed. --checksum sha256 is not the default; opkg
# asks for Packages.gz first and falls back to Packages, so both are written.
say "index: writing $PKG_FEED/Packages"
( cd "$PKG_FEED" && python3 "$OPKG_INDEX_BIN" --checksum md5 --checksum sha256 . > Packages )
gzip -n -9 -c "$PKG_FEED/Packages" > "$PKG_FEED/Packages.gz"
say "index: $(grep -c '^Package:' "$PKG_FEED/Packages") package(s) in $PKG_FEED"
