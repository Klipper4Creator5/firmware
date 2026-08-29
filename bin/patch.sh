#!/usr/bin/env bash
# 2/3 -- apply the mods to work/software/. Idempotent.
set -euo pipefail
. "$(dirname "$0")/common.sh"
. "$ROOT/pkgs/lib.sh"

SOFTWARE_DIR=work/software
[ -d "$SOFTWARE_DIR" ] || { echo "run bin/unpack.sh first" >&2; exit 1; }

# Counting .ipk, not testing the directory: a cleaned tree leaves it empty.
if [ -z "$(ls "$PKG_FEED"/*.ipk 2>/dev/null)" ]; then
    echo "no package feed at $PKG_FEED" >&2
    echo "  the recipes this script runs build against it -- run 'make packages' first." >&2
    exit 1
fi

say() { printf '>> %s\n' "$*"; }
skip() { printf '   (skip) %s\n' "$*"; }

# Built OUTSIDE the software component: /usr/prog is on the firmware partition
# and would overflow on ~100MB of Mainsail and HelixScreen.
rm -rf "$PAYLOAD_ROOT" "$SOFTWARE_DIR/mod"

# --- 0. the payload, installed
# Installed by the printer's own opkg inside the replica, so `opkg
# list-installed` answers what a release installs off the payload itself.
say "payload: installing the feed with the printer's own opkg"

# Not model-specific; TARGET_MACHINE names only the OUTPUT file, because
# runFirmwareExe.sh refuses a package whose machine is not its own.

# The roots, not the closure: Depends brings the rest, so the metadata is
# exercised on every build. A root with no .ipk is skipped -- that is how the
# PKG_WHEN gates reach here -- but a missing DEPENDENCY is still opkg's error.
# The two loose python packages are Recommends, which opkg has no field for.
#
# greenlet and cffi are deliberately NOT here: the klipper service execs
# $FF_PYTHON, so they are ordinary Depends of anvil-klipper now. Listed here
# they were installed by every build and by no `opkg install anvil-klipper`,
# which is the one command that has to work on a printer.
MOD_ROOTS="anvil-core anvil-opkg anvil-s6-rc anvil-klipper
           anvil-moonraker anvil-python-pillow anvil-python-preprocess-cancellation
           anvil-mainsail anvil-helixscreen anvil-busybox"

# Named, not versioned -- except anvil-core, whose PKG_VERSION is MOD_VER, so a
# feed built yesterday would install yesterday's anvil-core.
[ -f "$(pkg_ipk anvil-core)" ] || pkg_die \
    "the feed has no $(basename "$(pkg_ipk anvil-core)") -- rerun ./bin/build-packages.sh"

MOD_INSTALL=""
for _p in $MOD_ROOTS; do
    for _f in "$PKG_FEED/${_p}_"*.ipk; do
        if [ -f "$_f" ]; then MOD_INSTALL="$MOD_INSTALL $_p"; fi
        break
    done
done

# The machine's own opkg installs the feed onto its own filesystem: needs a
# privileged container, hence `make build`'s docker lane.
# shellcheck disable=SC2086
./bin/build-payload.py $MOD_INSTALL

say "payload: $(grep -c '^Package:' "$PAYLOAD_DIR/var/lib/opkg/status") packages installed (both chamber configs; the printer picks)"

# --- 1. Klipper
# Nothing is staged here any more: anvil-klipper installs the whole klippy tree
# at $MODDIR/klipper/klippy and the klipper s6-rc service execs it there on our
# own $FF_PYTHON, so the package IS the printer's Klipper. /usr/prog/klipper
# keeps FlashForge's stock klippy, unread -- except klipper_pri.sh (their
# SCHED_FIFO helper) and klipperDaemon, our shim, which the service greps
# KLIPPER_NICENESS out of.
#
# The assertion is all that is left, and it is cheap: an anvil-klipper that did
# not install is now a printer with no Klipper at all, with no component copy
# to mask it.
[ -d "$PAYLOAD_DIR/klipper/klippy" ] || pkg_die \
    "the payload has no $MODDIR/klipper/klippy -- anvil-klipper did not install"
[ -f "$PAYLOAD_DIR/klipper/klippy/chelper/c_helper.so" ] || pkg_die \
    "the payload has no $MODDIR/klipper/klippy/chelper/c_helper.so -- klippy cannot connect to an MCU without it"
say "Klipper: fork tree from pinned commit ${KLIPPER_VERSION:0:8} (payload only)"

# --- 2. Toolchanger
# Gone with section 1: the ff_*.py ride the klippy tree anvil-klipper installs
# and the ff-*.cfg are anvil-klipper-config's, so BUILD_TOOLCHANGE is answered
# entirely by that recipe's PKG_WHEN.

# --- 3. the user's seams
# In the payload and in NO package: a package member is overwritten on every
# upgrade by definition, and this is the user's own file.
[ -f pkgs/moonraker/seed/moonraker-custom.conf ] \
    && cp -f pkgs/moonraker/seed/moonraker-custom.conf "$PAYLOAD_DIR/config/moonraker-custom.conf"

# moonraker.conf ships with pkgs/moonraker, not anvil-core: unconditional, a
# BUILD_MOONRAKER=0 build overwrote the config of a server it did not install.

# --- 5b-2. the s6-rc database
# Compiled on the BUILD HOST, hence the second native build of the same four
# tarballs -- and byte-identical to a qemu target compile only BECAUSE both
# stacks are --prefix=$MODDIR: s6-rc-compile bakes the #! of the execline the
# COMPILER was linked against into the oneshot runner, so a different native
# prefix means ENOENT on every oneshot. The source comes out of the installed
# payload, so the database and the package cannot disagree.
S6RC_SRC="$PAYLOAD_DIR/etc/s6-rc/source"
S6RC_NATIVE="$PWD/work/.s6-native"
# The four versions and nothing else: this compiler is the build image's gcc.
S6RC_NATIVE_STAMP="$SKALIBS_VERSION $EXECLINE_VERSION $S6_VERSION $S6RC_VERSION"
[ -d "$S6RC_SRC" ] || { echo "   !! no s6-rc source tree at $S6RC_SRC" >&2; exit 1; }

if [ ! -x "$S6RC_NATIVE/bin/s6-rc-compile" ] \
   || [ "$(cat "$S6RC_NATIVE/.version" 2>/dev/null || true)" != "$S6RC_NATIVE_STAMP" ]; then
    say "s6-rc: building a native compiler ($SKALIBS_VERSION/$EXECLINE_VERSION/$S6_VERSION/$S6RC_VERSION)"
    rm -rf work/.s6-native work/.s6-native-src
    mkdir -p work/.s6-native-src
    for t in "$SKALIBS_TGZ" "$EXECLINE_TGZ" "$S6_TGZ" "$S6RC_TGZ"; do
        tar -xzf "$t" -C work/.s6-native-src
    done
    (
        # A subshell so nothing leaks into the rest of the build. Note no --host.
        set -e
        NSRC="$PWD/work/.s6-native-src"
        ND="$PWD/work/.s6-native-stage"
        rm -rf "$ND"
        export CFLAGS="-Os"
        JOBS=$(nproc 2>/dev/null || echo 4)
        for pkg in "skalibs-$SKALIBS_VERSION" "execline-$EXECLINE_VERSION" \
                   "s6-$S6_VERSION" "s6-rc-$S6RC_VERSION"; do
            cd "$NSRC/$pkg"
            if [ "$pkg" = "skalibs-$SKALIBS_VERSION" ]; then
                # configure can compile and RUN its probes: the target is here.
                ./configure --prefix="$MODDIR" \
                    --disable-shared --enable-static >/dev/null
            else
                ./configure --prefix="$MODDIR" \
                    --with-sysdeps="$ND$MODDIR/lib/skalibs/sysdeps" \
                    --with-include="$ND$MODDIR/include" \
                    --with-lib="$ND$MODDIR/lib" \
                    --disable-shared --enable-static >/dev/null
            fi
            make -j"$JOBS" >/dev/null
            make install DESTDIR="$ND" >/dev/null
        done
    )
    mkdir -p "$S6RC_NATIVE/bin"
    # s6-rc-db too: qa/static/test_s6rc_source.py reads the boot graph out of
    # the compiled database, and this is the only copy that runs on the host.
    for b in s6-rc-compile s6-rc-db; do
        cp -f "work/.s6-native-stage$MODDIR/bin/$b" "$S6RC_NATIVE/bin/"
    done
    rm -rf work/.s6-native-src work/.s6-native-stage
    echo "$S6RC_NATIVE_STAMP" > "$S6RC_NATIVE/.version"
else
    skip "s6-rc: native compiler already built for $S6RC_NATIVE_STAMP"
fi

# compiled/<stamp> with `current` a symlink, so the boot command never changes.
# Not /etc/s6-rc/, s6-rc-init's default, which is inside the read-only squashfs.
S6RC_DB_NAME="db-$MOD_VER"
rm -rf "$PAYLOAD_DIR/etc/s6-rc/compiled"
mkdir -p "$PAYLOAD_DIR/etc/s6-rc/compiled"
"$S6RC_NATIVE/bin/s6-rc-compile" \
    "$PAYLOAD_DIR/etc/s6-rc/compiled/$S6RC_DB_NAME" "$S6RC_SRC" || {
    echo "   !! s6-rc-compile refused $S6RC_SRC" >&2; exit 1; }
ln -sfn "$S6RC_DB_NAME" "$PAYLOAD_DIR/etc/s6-rc/compiled/current"

# The one assertion that catches a native stack built with the wrong prefix.
S6RC_RUNNER="$PAYLOAD_DIR/etc/s6-rc/compiled/$S6RC_DB_NAME/servicedirs/s6rc-oneshot-runner/run"
[ -f "$S6RC_RUNNER" ] || {
    echo "   !! s6-rc-compile produced no oneshot runner -- has the source tree no oneshots?" >&2
    exit 1; }
S6RC_SHEBANG=$(head -1 "$S6RC_RUNNER")
case "$S6RC_SHEBANG" in
    "#!$MODDIR/bin/execlineb"*) ;;
    *) echo "   !! the s6-rc database asks for '$S6RC_SHEBANG', not $MODDIR/bin/execlineb --" >&2
       echo "      the native stack was configured with the wrong --prefix" >&2
       exit 1 ;;
esac
say "s6-rc: database $S6RC_DB_NAME compiled -- $(ls "$S6RC_SRC" | wc -l) definitions"

# --- 6. SSH
# Nothing to install: the stock rootfs ships dropbear and an enabled
# S50dropbear, so ssh is already listening. Only the password is missing.
if [ -n "${ROOT_PW_HASH:-}" ]; then
    say "SSH: stock dropbear is already running; setting a known root password"
else
    say "SSH: no ROOT_PW_HASH -- the installer will pick a random root password"
    say "     and write it to anvil-password.txt on the USB stick."
    say "     Set ROOT_PW_HASH to choose your own instead."
fi
# --- 7. root password
if [ -n "${ROOT_PW_HASH:-}" ]; then
    say "Accounts: setting root password hash"
    # /etc is a bind mount of /usr/prog/etc, so this is the live shadow dropbear
    # reads at auth time, though it started from the read-only squashfs.
    awk -v h="$ROOT_PW_HASH" 'BEGIN{FS=OFS=":"} $1=="root"{$2=h} {print}' \
        "$SOFTWARE_DIR/shadow" > "$SOFTWARE_DIR/shadow.new" && mv -f "$SOFTWARE_DIR/shadow.new" "$SOFTWARE_DIR/shadow"
else
    skip "root password (set ROOT_PW_HASH)"
fi

# --- 8. firmwareExe + start.sh -- anvil-core's, and NOT in the component
# Both install at $MODDIR/prog/ and anvil-link-prog.sh points the stock paths
# at them, on the flash path (run-append.sh) and on `opkg upgrade anvil-core`
# (postinst). Nothing execs either between run.sh copying the component and
# link-prog running, so the component copy bought no ordering -- and it cost:
# our wrapper with no payload never starts a UI, it logs and sleeps for ever,
# turning a failed install into an unbootable printer. Absent, app_startup.sh
# restores a firmwareExe from a version directory and the stock recovery works.
# Stock run.sh is set -x, not set -e, so its two cp lines are noisy no-ops.
say "firmwareExe + start.sh: dropped from the component (anvil-core owns both)"
rm -f "$SOFTWARE_DIR/firmwareExe" "$SOFTWARE_DIR/start.sh"

# --- 10. anvil.conf
# anvil.conf is not in anvil-core and is the whole of what is left here:
# preserved across updates by run-append.sh, which makes it user state rather
# than a package member. Only the two values with a RANGE are substituted.
sed -e "s/^NICE_MOONRAKER=.*/NICE_MOONRAKER=${NICE_MOONRAKER:-5}/" \
    -e "s/^NICE_CAM=.*/NICE_CAM=${NICE_CAM:-10}/" \
    pkgs/anvil-core/seed/anvil.conf.in > "$PAYLOAD_DIR/anvil.conf"

# --- 10b. the install manifest
# Every path this payload installs, so the next update deletes exactly what this
# one left behind -- a renamed init script leaves no stale twin. It names
# ITSELF, and is moved in from a temp file so `find` cannot list a
# half-written manifest.
MOD_MANIFEST=.install-manifest
{ ( cd "$PAYLOAD_DIR" && find . -mindepth 1 | sed 's|^\./||' )
  echo "$MOD_MANIFEST"
} | LC_ALL=C sort -u > work/.install-manifest
mv -f work/.install-manifest "$PAYLOAD_DIR/$MOD_MANIFEST"
say "install manifest: $(wc -l < "$PAYLOAD_DIR/$MOD_MANIFEST") paths -> $MODDIR/$MOD_MANIFEST"

# --- 11. run.sh install step
say "run.sh: injecting mod install blocks (pre + post)"
POST=work/.run-post.sh
# A baked-in default would be the same password on every printer.
if [ -z "${ROOT_PW_HASH:-}" ]; then
    PW_AUTO=1
else
    PW_AUTO=0
fi
sed -e "s/^MOD_PW_AUTO=.*/MOD_PW_AUTO=$PW_AUTO/" \
    installer/run-append.sh > "$POST"
python3 - "$SOFTWARE_DIR/run.sh" installer/run-pre.sh "$POST" <<'PY'
import sys, re
run, pre_f, post_f = sys.argv[1], sys.argv[2], sys.argv[3]
B1, E1 = "# >>> anvil pre >>>",  "# <<< anvil pre <<<"
B2, E2 = "# >>> anvil begin >>>", "# <<< anvil end <<<"
src = open(run, encoding='utf-8', errors='surrogateescape').read()
# idempotent: strip any previous injection
for b, e in ((B1, E1), (B2, E2)):
    src = re.sub(re.escape(b) + r".*?" + re.escape(e) + r"\n?", "", src, flags=re.S)

pre  = B1 + "\n" + open(pre_f,  encoding='utf-8').read() + E1 + "\n"
post = B2 + "\n" + open(post_f, encoding='utf-8').read() + E2 + "\n\n"

# After WORK_DIR is defined, before the first cp into /usr/prog.
m = re.search(r"^WORK_DIR=.*$", src, flags=re.M)
if not m:
    raise SystemExit("run.sh has no WORK_DIR assignment -- cannot place the pre-block")
i = m.end()
src = src[:i] + "\n\n" + pre + src[i:]
print("   pre-block inserted after WORK_DIR")

m = list(re.finditer(r"^exit 0\s*$", src, flags=re.M))
j = m[-1].start() if m else len(src)
src = src[:j] + post + src[j:]
print("   post-block inserted before exit")
open(run, 'w', encoding='utf-8', errors='surrogateescape').write(src)
PY
chmod +x "$SOFTWARE_DIR/run.sh"
rm -f "$POST"

echo
echo "Patched."
echo "  software component: $(du -sh "$SOFTWARE_DIR" | cut -f1)  (-> /usr/prog, firmware partition)"
echo "  mod payload:        $(du -sh "$PAYLOAD_DIR" | cut -f1)  (-> /usr/data/anvil, data partition)"
echo "Now run ./bin/pack.sh"
