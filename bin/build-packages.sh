#!/usr/bin/env bash
# Build every recipe under pkgs/ into the feed, in dependency order, and index
# it.
#
#     ./bin/build-packages.sh              all recipes
#     ./bin/build-packages.sh apk-tools    that one and everything it needs
#
# Each recipe is packaged before the next is built, because a recipe gets its
# PKG_BUILD_DEPENDS out of this feed. The archives are apk's own work; what
# is left here is laying out the tree it packages.
#
# Needs no stock FlashForge package, unlike bin/payload.sh, so packaging stays
# runnable in CI on a bare checkout.
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$ROOT/pkgs/lib.sh"

say() { printf '>> %s\n' "$*"; }

# THE PACKAGER IS BUILT ON DEMAND, like every other build input here: the
# cross toolchain is unpacked by pkg_toolchain and the build-python compiled by
# pkg_buildpython, both stamped so the second call is a no-op. There is no
# reason for the one tool that writes the packages to be the one thing a person
# has to remember to build first.
#
# tools/apk-host/build.sh caches on the pin and prints `(skip)` when it is
# already current, so this costs a stamp comparison on a warm tree.
./tools/apk-host/build.sh || {
    echo "!! could not build the native apk that writes the feed" >&2; exit 1; }

# THE ID MAP, written once per run. apk resolves the owner of every file
# to a NAME against <--root>/etc/passwd, and the build lane runs as a user
# with no entry there, so without this every package records `nobody`.
# Measured, silent, and it changes the archive's directory entries as well
# as its metadata -- see emit_apk and qa/static/test_apk.py.
#
# --root reaches ONLY the id cache and the trust keys directory: mkpkg
# opens -F and -o relative to the working directory, so this cannot move
# where a package is read from or written to.
APK_IDROOT="$ROOT/work/.apk-root"
rm -rf "$APK_IDROOT"
mkdir -p "$APK_IDROOT/etc"
printf 'root:x:%s:%s:::\n' "$(id -u)" "$(id -g)" > "$APK_IDROOT/etc/passwd"
printf 'root:x:%s:\n'      "$(id -g)"            > "$APK_IDROOT/etc/group"

# --- signing, when a key is configured
# AN UNSIGNED FEED IS A WORKING ONE, and stays that way: `make packages`
# has to run on a bare checkout with no secrets or the packaging lane
# stops being a CI gate. So this is a branch on config.env, not a
# requirement.
APK_SIGN=""
APK_UNTRUSTED="--allow-untrusted"
if [ -n "${APK_SIGN_KEY:-}" ]; then
    [ -f "$APK_SIGN_KEY" ] || {
        echo "!! APK_SIGN_KEY names $APK_SIGN_KEY, which does not exist." >&2
        echo "   ./bin/apk-keygen.sh makes the pair; leave the setting" >&2
        echo "   empty to build an unsigned feed." >&2
        exit 1; }
    [ -f "$APK_SIGN_KEY.pub" ] || {
        echo "!! $APK_SIGN_KEY.pub is missing. The public half is what a" >&2
        echo "   printer verifies with and what mkndx checks the feed" >&2
        echo "   against; regenerate it with:" >&2
        echo "     openssl pkey -in $APK_SIGN_KEY -pubout -out $APK_SIGN_KEY.pub" >&2
        exit 1; }
    APK_SIGN="--sign-key $APK_SIGN_KEY"
    # The trust directory apk reads is <--root>/etc/apk/keys, and --root
    # is already the id map -- so the same synthetic root that makes
    # ownership right is what lets mkndx verify the packages it indexes.
    mkdir -p "$APK_IDROOT/etc/apk/keys"
    cp -f "$APK_SIGN_KEY.pub" "$APK_IDROOT/etc/apk/keys/"
    APK_UNTRUSTED=""
    say "signing: $(basename "$APK_SIGN_KEY")"
else
    say "signing: none -- set APK_SIGN_KEY in config.env to sign the feed"
fi

# Reproducible by default: mkpkg replaces every mtime with SOURCE_DATE_EPOCH
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
        # mkpkg takes a DIRECTORY: the tree as it appears on the target,
        # laid down under $MODDIR so an install needs no prefix.
        # cp -a, not cp: libsodium's .so -> .so.26 -> .so.26.2.0 chain would
        # become three 400KB files.
        LAYOUT="work/.pkg-$PKG_NAME"
        rm -rf "$LAYOUT"
        mkdir -p "$LAYOUT$MODDIR"
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
        DEVLAYOUT="work/.pkg-$PKG_NAME-dev"
        rm -rf "$DEVLAYOUT"
        if [ -n "$PKG_DEV_FILES" ]; then
            mkdir -p "$DEVLAYOUT$MODDIR"
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

        # emit_apk -- the same package, written by apk's own packager.
        #
        # Metadata goes on the COMMAND LINE, not into a file beside the tree:
        # `-I key:value` reaches any field of apk's pkginfo schema, and the
        # scripts are read into the archive rather than copied to a directory.
        # So there is no CONTROL/ here, and no chmod: a script's mode stops
        # mattering once its bytes are the package.
        emit_apk() {
            # --root IS THE ID MAP, AND IT IS NOT OPTIONAL. apk records
            # ownership by NAME, resolved against <root>/etc/passwd. The build
            # lane runs --user with no passwd entry (Makefile, DOCKER_USER),
            # so without this every file in every package is recorded `nobody`
            # -- measured -- and installs on the printer as uid 65534, with no
            # error at build or install time. mkpkg's empty-directory prune
            # also fires only for root:root 0755, so the wrong owner changes
            # the set of entries too. qa/static/test_apk.py gates both halves.
            set -- --root "$APK_IDROOT" mkpkg \
                --no-xattrs \
                -I "name:$_nm" \
                -I "version:$_fullver" \
                -I "arch:$_arch" \
                -I "maintainer:$PKG_MAINTAINER" \
                -I "description:$_desc"

            # CONFLICTS ARE NEGATED DEPENDENCIES. apk has no Conflicts field:
            # `!name` inside depends is how the same thing is said, and a
            # versioned `provides` conflicts on its own. No recipe sets either
            # today, so this is plumbing with no user -- kept because the
            # chamber-config problem it was built for can come back.
            # COMMAS COME OFF HERE AND ONLY HERE. Recipes write `a, b, c` for
            # a comma-separated list, which is what the recipes were written
            # for; apk's is whitespace-separated and would take a trailing
            # comma as part of the package name it looks for.
            # shellcheck disable=SC2086
            for _c in $PKG_CONFLICTS; do _dep="$_dep !$_c"; done
            # shellcheck disable=SC2086
            _dep=$(echo $_dep | tr -d ',')
            [ -n "$_dep" ] && set -- "$@" -I "depends:$_dep"
            # shellcheck disable=SC2086
            [ -n "$PKG_PROVIDES" ] && set -- "$@" -I "provides:$(echo $PKG_PROVIDES)"

            # Maintainer scripts, runtime package only, for the reason the ipk
            # -dev half would act on a payload that is not its own. THE NAME
            # TABLE IS THE POINT: apk picks post-install or post-upgrade with
            # no fallback (src/database.c), so a package carrying only
            # post-install silently does nothing on upgrade -- and
            # anvil-core's is what relinks /usr/prog. One file, declared twice.
            if [ "$_nm" = "$PKG_NAME" ] && [ -d "$PKG_DIR/control" ]; then
                for _cs in "$PKG_DIR"/control/*; do
                    [ -f "$_cs" ] || continue
                    case "$(basename "$_cs")" in
                        preinst)  set -- "$@" -s "pre-install:$_cs" ;;
                        postinst) set -- "$@" -s "post-install:$_cs" \
                                             -s "post-upgrade:$_cs" ;;
                        prerm)    set -- "$@" -s "pre-deinstall:$_cs" ;;
                        postrm)   set -- "$@" -s "post-deinstall:$_cs" ;;
                        # apk's own names pass through, so a recipe that wants
                        # to distinguish install from upgrade can say so.
                        pre-install|post-install|pre-upgrade|post-upgrade|\
                        pre-deinstall|post-deinstall|trigger)
                            set -- "$@" -s "$(basename "$_cs"):$_cs" ;;
                        conffiles)
                            echo "!! $r: apk has no conffiles equivalent, and" >&2
                            echo "   dropping it silently is how a user's config" >&2
                            echo "   gets overwritten. See apk-protected_paths(5)." >&2
                            exit 1 ;;
                        *)
                            echo "!! $r: control/$(basename "$_cs") is not a" >&2
                            echo "   maintainer script name -- a typo here would" >&2
                            echo "   otherwise ship nothing and say nothing." >&2
                            exit 1 ;;
                    esac
                done
            fi

            # THE VERSION, CHECKED HERE, because mkpkg's own refusal names
            # neither the package nor the value: it says "info field 'version'
            # has invalid value" and stops. MOD_VER=ci in a workflow reached
            # this and cost a CI round trip to identify. pkg_version_ok is the
            # same grammar qa/static/test_apk.py holds every recipe to; this
            # catches the versions that come from config.env instead, which no
            # test of the recipes can see.
            pkg_version_ok "$_fullver" || {
                echo "!! $_nm's version '$_fullver' is not one apk can parse." >&2
                echo "   The grammar is number{.number}{letter}{_suffix}{~hash}{-r#}:" >&2
                echo "   it has to start with a digit. If that value came from" >&2
                echo "   MOD_VER or another config.env setting, fix it there." >&2
                exit 1
            }

            _out="$PKG_FEED/${_nm}-${_fullver}.apk"
            # $APK_SIGN is empty when no key is configured, and an unsigned
            # package is a valid one -- apk simply writes no signature block.
            # shellcheck disable=SC2086
            "$APK_BIN" $APK_SIGN "$@" -F "$_lay" -o "$_out" \
                || { echo "!! apk mkpkg failed for $_nm" >&2; exit 1; }
            [ -f "$_out" ] || { echo "!! apk mkpkg produced no $_out" >&2; exit 1; }
        }

        # emit <layout> <name> <depends> <description>
        emit() {
            _lay=$1; _nm=$2; _dep=$3; _desc=$4
            _fullver=$(pkg_fullversion "$PKG_VERSION" "$PKG_RELEASE")
            _arch=$(pkg_arch "$PKG_ARCH")
            # ONE LINE: a raw newline in a metadata field is a new stanza to
            # some parsers and a continuation to others. Unquoted, so it
            # re-splits.
            # shellcheck disable=SC2086
            _dep=$(echo $_dep)

            emit_apk
            rm -rf "$_lay"
            say "$_nm: $(basename "$_out") ($(du -h "$_out" | cut -f1))"
        }

        # Unless the split took everything -- normal for a link-only library.
        if [ -n "$(find "$LAYOUT$MODDIR" \( -type f -o -type l \) -print -quit)" ]; then
            emit "$LAYOUT" "$PKG_NAME" "$PKG_DEPENDS" "$PKG_DESCRIPTION"
        else
            rm -rf "$LAYOUT"
        fi

        # By name: the dev half's headers describe that build of the library.
        # Tested on the TREE, not on CONTROL/, which only the ipk path creates.
        if [ -d "$DEVLAYOUT$MODDIR" ]; then
            if [ -f "$(pkg_pkgfile "$r")" ]; then
                _devdep="$PKG_NAME"
            else
                _devdep=""
            fi
            emit "$DEVLAYOUT" "$PKG_NAME-dev" "$_devdep" \
                 "${PKG_DEV_DESCRIPTION:-Headers and static library for $PKG_NAME. Nothing installs this on a printer; it exists to be built against.}"
        fi
    )
done

# --- the prune
# An orphan package goes into the index and a printer can install something no
# recipe builds any more. Full builds only, and the expected set comes from
# ALL recipes, not the ones this run built.
#
# The expected names come from pkg_pkgfile, which is also what wrote them --
# when the two disagreed, this deleted seventeen packages the same run had
# just built and still exited 0. qa/static/test_apk.py watches for that now.
if [ $# -eq 0 ]; then
    expected=""
    for r in $(pkg_recipes); do
        for v in '' dev; do
            expected="$expected $(basename "$(pkg_pkgfile "$r" "$v")")"
        done
    done
    for f in "$PKG_FEED"/*."$PKG_EXT"; do
        [ -e "$f" ] || continue
        case " $expected " in
            *" $(basename "$f") "*) continue ;;
        esac
        say "prune: $(basename "$f") -- no recipe produces this any more"
        rm -f "$f"
    done
fi

# --- the index
say "index: writing $PKG_FEED/$PKG_INDEX_NAME"
# ONE FILE, and its NAME IS THE REPOSITORY SYNTAX. apk decides how to read
# a repository from how the entry is spelled: a path ending `.adb` is a v3
# index read in place, and the packages are its siblings named
# `${name}-${version}.apk`. A bare directory would instead send it looking
# for `<dir>/<arch>/Packages.adb` and an arch subdirectory of packages.
# Naming the index file directly is what keeps the feed flat, which is
# what bin/payload.sh and the simulated stick already expect.
#
# mkndx reads each package's metadata out of the package itself and adds
# the file size and hash, so nothing here restates what emit_apk wrote.
#
# mkndx VERIFIES EVERY PACKAGE IT INDEXES and refuses the lot on one bad
# signature. With a key configured that is exactly the check we want, and
# $APK_UNTRUSTED is empty so it runs; without one, an unsigned package is
# not a broken package and the flag is what says so.
# shellcheck disable=SC2086
( cd "$PKG_FEED" && "$APK_BIN" --root "$APK_IDROOT" $APK_SIGN $APK_UNTRUSTED \
    mkndx --hash sha256 -o "$PKG_INDEX_NAME" ./*."$PKG_EXT" ) > /dev/null
say "index: $(ls "$PKG_FEED"/*."$PKG_EXT" | wc -l) package(s) in $PKG_FEED"
